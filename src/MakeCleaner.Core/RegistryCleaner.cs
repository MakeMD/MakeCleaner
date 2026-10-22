using System.Text;
using Microsoft.Win32;

namespace MakeCleaner;

// ValueName == null -> the whole key is the problem; "" -> the default value.
public record RegIssue(string Category, string Problem, string Data, string KeyPath, string? ValueName)
{
    public string Target => ValueName == null ? KeyPath : $@"{KeyPath}\{(ValueName == "" ? "(Default)" : ValueName)}";
}

public record RegCategory(string Name, Func<RegScanner, IEnumerable<RegIssue>> Scan);

// Read-only scanner. hkcu/hklm are the roots to scan: the real hives in the app,
// a throwaway HKCU\Software\MakeCleanerTest-<guid> branch in tests.
// Every check is conservative: anything we cannot resolve to a local absolute path is NOT an issue.
public class RegScanner(RegistryKey hkcu, RegistryKey hklm)
{
    const string Cv = @"SOFTWARE\Microsoft\Windows\CurrentVersion";
    const string Wow = @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion";

    public static RegScanner ForThisPc() => new(Registry.CurrentUser, Registry.LocalMachine);

    public static readonly RegCategory[] Categories =
    [
        new("Missing Shared DLLs", s => s.SharedDlls()),
        new("Unused File Extensions", s => s.FileExtensions()),
        new("ActiveX and Class Issues", s => s.ComClasses()),
        new("Type Libraries", s => s.TypeLibs()),
        new("Applications", s => s.OpenWithApps()),
        new("Fonts", s => s.Fonts()),
        new("Application Paths", s => s.AppPaths()),
        new("Help Files", s => s.HelpFiles()),
        new("Installer", s => s.InstallerFolders()),
        new("Obsolete Software", s => s.ObsoleteSoftware()),
        new("Run At Startup", s => s.RunAtStartup()),
        new("Start Menu Ordering", s => s.StartMenuOrder()),
        new("MUI Cache", s => s.MuiCache()),
        new("Sound Events", s => s.SoundEvents()),
        new("Windows Services", s => s.Services()),
    ];

    public List<RegIssue> Scan(IEnumerable<RegCategory> cats, ICollection<string> excluded, CancellationToken ct = default)
    {
        var all = new List<RegIssue>();
        foreach (var c in cats)
            foreach (var i in c.Scan(this))
            {
                ct.ThrowIfCancellationRequested();
                if (!IsExcluded(i, excluded)) all.Add(i);
            }
        return all;
    }

    static bool IsExcluded(RegIssue i, ICollection<string> excluded) =>
        excluded.Select(e => e.TrimEnd('\\')).Any(e => i.Target.Equals(e, StringComparison.OrdinalIgnoreCase)
            || i.Target.StartsWith(e + @"\", StringComparison.OrdinalIgnoreCase));

    // --- categories ---

    // SharedDLLs: value name = refcounted file path.
    IEnumerable<RegIssue> SharedDlls() =>
        from root in Roots(hklm, $@"{Cv}\SharedDLLs", $@"{Wow}\SharedDLLs")
        from name in Values(root)
        where Missing(name)
        select V("Missing Shared DLLs", "Missing Shared DLL", name, root, name);

    // .ext whose ProgID points nowhere and that carries nothing else.
    IEnumerable<RegIssue> FileExtensions()
    {
        using var classes = hkcu.OpenSubKey(@"Software\Classes");
        if (classes == null) yield break;
        foreach (var ext in classes.GetSubKeyNames().Where(n => n.StartsWith('.')))
        {
            using var k = Open(classes, ext);
            if (k == null || k.SubKeyCount > 0 || k.ValueCount != 1) continue;
            if (k.GetValue("") is string progId && progId.Length > 0 && !ClassExists(progId))
                yield return new("Unused File Extensions", "Unused File Extension", $"{ext} -> {progId}", k.Name, null);
        }
    }

    // Per-user COM registrations whose server binary is gone.
    IEnumerable<RegIssue> ComClasses()
    {
        using var clsid = hkcu.OpenSubKey(@"Software\Classes\CLSID");
        if (clsid == null) yield break;
        foreach (var id in clsid.GetSubKeyNames())
        {
            using var k = Open(clsid, id);
            if (k == null) continue;
            foreach (var server in new[] { "InprocServer32", "LocalServer32" })
                if (Default(k, server) is { } cmd && MissingCommand(cmd))
                {
                    yield return new("ActiveX and Class Issues", "ActiveX/COM Issue", cmd, k.Name, null);
                    break;
                }
        }
    }

    // TypeLib\{guid}\{ver}\{lcid}\win32|win64 -> .tlb/.dll path.
    IEnumerable<RegIssue> TypeLibs()
    {
        using var tl = hkcu.OpenSubKey(@"Software\Classes\TypeLib");
        if (tl == null) yield break;
        foreach (var id in tl.GetSubKeyNames())
        {
            using var g = Open(tl, id);
            if (g == null) continue;
            foreach (var ver in g.GetSubKeyNames())
            {
                using var v = Open(g, ver);
                if (v == null) continue;
                var paths = (from lcid in v.GetSubKeyNames()
                             from plat in new[] { "win32", "win64" }
                             let p = Default(v, $@"{lcid}\{plat}")
                             where p != null
                             select p).ToList();
                if (paths.Count > 0 && paths.All(MissingCommand))
                    yield return new("Type Libraries", "Missing TypeLib reference", paths[0], v.Name, null);
            }
        }
    }

    // Classes\Applications\<exe>\shell\<verb>\command -> program that no longer exists.
    IEnumerable<RegIssue> OpenWithApps()
    {
        using var apps = hkcu.OpenSubKey(@"Software\Classes\Applications");
        if (apps == null) yield break;
        foreach (var app in apps.GetSubKeyNames())
        {
            using var shell = apps.OpenSubKey($@"{app}\shell");
            if (shell == null) continue;
            var cmds = shell.GetSubKeyNames().Select(verb => Default(shell, $@"{verb}\command")).OfType<string>().ToList();
            if (cmds.Count > 0 && cmds.All(MissingCommand))
                yield return new("Applications", "Open with Application Issue", cmds[0], $@"{apps.Name}\{app}", null);
        }
    }

    // Fonts: data is a bare file name (=> %windir%\Fonts) or a full path (per-user fonts).
    IEnumerable<RegIssue> Fonts()
    {
        var fontsDir = Environment.GetFolderPath(Environment.SpecialFolder.Fonts);
        foreach (var hive in new[] { hkcu, hklm })
            foreach (var root in Roots(hive, @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"))
                foreach (var name in Values(root))
                    if (root.GetValue(name) is string file && file.Length > 0
                        && Missing(Path.IsPathRooted(file) ? file : Path.Combine(fontsDir, file)))
                        yield return V("Fonts", "Font Issue", file, root, name);
    }

    IEnumerable<RegIssue> AppPaths()
    {
        foreach (var hive in new[] { hkcu, hklm })
            foreach (var root in Roots(hive, $@"{Cv}\App Paths", $@"{Wow}\App Paths"))
                foreach (var exe in root.GetSubKeyNames())
                    if (Default(root, exe) is { } p && MissingCommand(p))
                        yield return new("Application Paths", "Application Paths Issue", p, $@"{root.Name}\{exe}", null);
    }

    // Help: value name = file name, data = folder.
    IEnumerable<RegIssue> HelpFiles() =>
        from root in Roots(hklm, @"SOFTWARE\Microsoft\Windows\Help", @"SOFTWARE\Microsoft\Windows\HTML Help",
                           @"SOFTWARE\WOW6432Node\Microsoft\Windows\Help", @"SOFTWARE\WOW6432Node\Microsoft\Windows\HTML Help")
        from name in Values(root)
        let dir = root.GetValue(name) as string
        where name.Length > 0 && !string.IsNullOrEmpty(dir) && Missing(Path.Combine(dir, name))
        select V("Help Files", "Help File Issue", Path.Combine(dir!, name), root, name);

    // Installer\Folders: value name = folder Windows Installer created.
    IEnumerable<RegIssue> InstallerFolders() =>
        from root in Roots(hklm, $@"{Cv}\Installer\Folders")
        from name in Values(root)
        where Missing(name)
        select V("Installer", "Installer Reference Issue", name, root, name);

    // HKCU\Software\<vendor> keys left completely empty by uninstallers.
    IEnumerable<RegIssue> ObsoleteSoftware()
    {
        using var sw = hkcu.OpenSubKey("Software");
        if (sw == null) yield break;
        foreach (var name in sw.GetSubKeyNames())
        {
            using var k = Open(sw, name);
            if (k != null && k.SubKeyCount == 0 && k.ValueCount == 0)
                yield return new("Obsolete Software", "Obsolete software key", name, k.Name, null);
        }
    }

    IEnumerable<RegIssue> RunAtStartup()
    {
        foreach (var hive in new[] { hkcu, hklm })
            foreach (var root in Roots(hive, $@"{Cv}\Run", $@"{Cv}\RunOnce", $@"{Wow}\Run", $@"{Wow}\RunOnce"))
                foreach (var name in Values(root))
                    if (root.GetValue(name) is string cmd && MissingCommand(cmd))
                        yield return V("Run At Startup", "Missing Startup Software", cmd, root, name);
    }

    // MenuOrder\Start Menu2\Programs\<folder>: ordering cache for Start Menu folders that are gone.
    IEnumerable<RegIssue> StartMenuOrder()
    {
        using var order = hkcu.OpenSubKey($@"{Cv}\Explorer\MenuOrder\Start Menu2\Programs");
        if (order == null) yield break;
        string[] bases =
        [
            Environment.GetFolderPath(Environment.SpecialFolder.Programs),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms),
        ];
        foreach (var name in order.GetSubKeyNames())
            if (!bases.Any(b => Directory.Exists(Path.Combine(b, name))))
                yield return new("Start Menu Ordering", "Old Start Menu key", name, $@"{order.Name}\{name}", null);
    }

    // MuiCache: "C:\x\app.exe.FriendlyAppName" -> the exe part.
    IEnumerable<RegIssue> MuiCache()
    {
        foreach (var root in Roots(hkcu, @"Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache"))
            foreach (var name in Values(root))
            {
                var dot = name.LastIndexOf('.');
                if (name.StartsWith('@') || dot <= 0) continue;
                if (Missing(name[..dot]))
                    yield return V("MUI Cache", "Missing MUI reference", name[..dot], root, name);
            }
    }

    // AppEvents\Schemes\Apps\<app>\<event>\<scheme> default = .wav path.
    IEnumerable<RegIssue> SoundEvents()
    {
        using var apps = hkcu.OpenSubKey(@"AppEvents\Schemes\Apps");
        if (apps == null) yield break;
        foreach (var app in apps.GetSubKeyNames())
        {
            using var a = Open(apps, app);
            if (a == null) continue;
            foreach (var ev in a.GetSubKeyNames())
            {
                using var e = Open(a, ev);
                if (e == null) continue;
                foreach (var scheme in e.GetSubKeyNames())
                {
                    using var s = Open(e, scheme);
                    if (s?.GetValue("") is string wav && wav.Length > 0 && Missing(wav))
                        yield return new("Sound Events", "Invalid file reference", wav, s.Name, "");
                }
            }
        }
    }

    // Only user-mode services (Type 0x10 / 0x20); drivers are never touched.
    IEnumerable<RegIssue> Services()
    {
        using var svcs = hklm.OpenSubKey(@"SYSTEM\CurrentControlSet\Services");
        if (svcs == null) yield break;
        foreach (var name in svcs.GetSubKeyNames())
        {
            using var k = Open(svcs, name);
            if (k == null || k.GetValue("Type") is not int type || (type & 0x30) == 0) continue;
            if (k.GetValue("ImagePath") is string img && MissingCommand(ServicePath(img)))
                yield return new("Windows Services", "Invalid service image path", img, k.Name, null);
        }
    }

    // --- helpers ---

    static RegIssue V(string cat, string problem, string data, RegistryKey key, string value) => new(cat, problem, data, key.Name, value);

    // Opens each existing relative path; the yielded keys are disposed by the caller's enumeration end (GC is fine for read handles).
    static IEnumerable<RegistryKey> Roots(RegistryKey hive, params string[] paths)
    {
        foreach (var p in paths)
            if (Open(hive, p) is { } k) yield return k;
    }

    static RegistryKey? Open(RegistryKey parent, string name)
    {
        try { return parent.OpenSubKey(name); }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException) { return null; }
    }

    static string[] Values(RegistryKey k)
    {
        try { return k.GetValueNames(); }
        catch (IOException) { return []; }
    }

    static string? Default(RegistryKey k, string sub)
    {
        using var s = Open(k, sub);
        return s?.GetValue("") as string is { Length: > 0 } v ? v : null;
    }

    bool ClassExists(string progId) =>
        Open(hkcu, $@"Software\Classes\{progId}") is { } a && Dispose(a)
        || Open(hklm, $@"SOFTWARE\Classes\{progId}") is { } b && Dispose(b);

    static bool Dispose(RegistryKey k) { k.Dispose(); return true; }

    // "\SystemRoot\x", "\??\C:\x", "system32\x" (relative to %windir%) -> absolute.
    static string ServicePath(string img)
    {
        var p = Environment.ExpandEnvironmentVariables(img.Trim());
        var win = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        if (p.StartsWith(@"\SystemRoot\", StringComparison.OrdinalIgnoreCase)) return Path.Combine(win, p[12..]);
        if (p.StartsWith(@"\??\")) return p[4..];
        if (p.StartsWith(@"system32\", StringComparison.OrdinalIgnoreCase)) return Path.Combine(win, p);
        return p;
    }

    public static bool MissingCommand(string cmd) => ExtractPath(cmd) is { } p && Missing(p);

    // Path of the program/file in a command line or icon reference; null when we can't tell for sure.
    public static string? ExtractPath(string cmd)
    {
        var s = Environment.ExpandEnvironmentVariables(cmd.Trim());
        if (s.Length == 0) return null;
        if (s[0] == '"')
        {
            var end = s.IndexOf('"', 1);
            if (end < 0) return null;
            s = s[1..end];
        }
        else
        {
            var comma = s.LastIndexOf(',');
            if (comma > 0 && int.TryParse(s[(comma + 1)..].Trim(), out _)) s = s[..comma]; // "file.dll,-101"
            if (!File.Exists(s))
            {
                // unquoted "C:\Program Files\x\app.exe /arg": cut after the first executable extension
                var m = System.Text.RegularExpressions.Regex.Match(s, @"^.+?\.(exe|dll|ocx|cpl|com|scr|tlb|olb|sys)(?=\s|$)",
                    System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                if (m.Success) s = m.Value;
            }
        }
        // rundll32: the real dll is an argument; '%': unexpanded variable in the path itself
        if (s.Contains("rundll32", StringComparison.OrdinalIgnoreCase) || s.Contains('%')) return null;
        return IsLocalAbsolute(s) ? s : null;
    }

    static bool IsLocalAbsolute(string p) =>
        p.Length >= 3 && char.IsLetter(p[0]) && p[1] == ':' && p[2] == '\\'
        && Directory.Exists(p[..3]); // unplugged/removable drive -> unknown, not an issue

    // Missing only when it is a local absolute path and neither the file, the folder, nor the WOW64 twin exists.
    public static bool Missing(string path)
    {
        if (!IsLocalAbsolute(path) || path.IndexOfAny(Path.GetInvalidPathChars()) >= 0) return false;
        if (File.Exists(path) || Directory.Exists(path)) return false;
        var wow = path.Replace(@"\System32\", @"\SysWOW64\", StringComparison.OrdinalIgnoreCase);
        if (wow != path && File.Exists(wow)) return false;
        return CanList(DeepestExistingFolder(path)); // *.Exists says false on access denied too
    }

    static string? DeepestExistingFolder(string path)
    {
        var p = Path.GetDirectoryName(path.TrimEnd('\\'));
        while (p != null && !Directory.Exists(p)) p = Path.GetDirectoryName(p);
        return p;
    }

    static bool CanList(string? dir)
    {
        if (dir == null) return false;
        try { using var e = Directory.EnumerateFileSystemEntries(dir).GetEnumerator(); e.MoveNext(); return true; }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException) { return false; }
    }
}

// Writes a regedit-importable backup of everything a fix will remove, then removes it.
public static class RegFix
{
    public record Result(int Fixed, int Failed);

    public static Result Fix(IReadOnlyList<RegIssue> issues, string backupPath, Func<string, bool>? importElevated = null)
    {
        WriteBackup(issues, backupPath); // throws before any change if the backup can't be written
        return Apply(issues, importElevated);
    }

    // Removes the issues. Only for callers that already wrote the backup of all of them (the fix-by-fix dialog).
    // Most issues live in HKLM/HKCR, which a normal user cannot write: whatever is denied goes into one deletion .reg
    // imported elevated, so a whole batch costs one UAC prompt. The result is the registry's real state afterwards,
    // never "we tried": an issue counts as fixed only when its key/value is gone.
    public static Result Apply(IReadOnlyList<RegIssue> issues, Func<string, bool>? importElevated = null)
    {
        foreach (var i in issues)
        {
            try
            {
                if (i.ValueName == null)
                {
                    var (parent, leaf) = SplitParent(i.KeyPath);
                    using var p = OpenKey(parent, writable: true);
                    p?.DeleteSubKeyTree(leaf, throwOnMissingSubKey: false);
                }
                else
                {
                    using var k = OpenKey(i.KeyPath, writable: true);
                    k?.DeleteValue(i.ValueName, throwOnMissingValue: false);
                }
            }
            catch (Exception e) when (e is UnauthorizedAccessException or System.Security.SecurityException or IOException) { }
        }
        // Decide by what is still there, not by exceptions: DeleteSubKeyTree(throwOnMissingSubKey: false) silently does
        // nothing when the key can't be opened for writing (access denied looks like "missing" to it).
        var denied = issues.Where(Exists).ToList();
        if (denied.Count > 0)
        {
            var tmp = Path.Combine(Path.GetTempPath(), $"MakeCleaner-fix-{Guid.NewGuid():N}.reg");
            try
            {
                File.WriteAllText(tmp, DeletionScript(denied), Encoding.Unicode);
                (importElevated ?? ImportElevated)(tmp);
            }
            finally { File.Delete(tmp); }
        }
        var fixedCount = issues.Count(i => !Exists(i));
        return new Result(fixedCount, issues.Count - fixedCount);
    }

    // false = UAC declined or reg.exe failed; Apply re-reads the registry either way.
    static bool ImportElevated(string regFile) => Elevated.Run("reg.exe", $"import \"{regFile}\" /reg:64");

    // regedit syntax for removal: [-key] deletes a key tree, "name"=- / @=- deletes one value.
    public static string DeletionScript(IEnumerable<RegIssue> issues)
    {
        var sb = new StringBuilder("Windows Registry Editor Version 5.00\r\n");
        foreach (var i in issues)
            sb.Append(i.ValueName == null
                ? $"\r\n[-{i.KeyPath}]\r\n"
                : $"\r\n[{i.KeyPath}]\r\n{(i.ValueName == "" ? "@" : $"\"{Esc(i.ValueName)}\"")}=-\r\n");
        return sb.ToString();
    }

    public static bool Exists(RegIssue i)
    {
        try
        {
            using var k = OpenKey(i.KeyPath, writable: false);
            return k != null && (i.ValueName == null || k.GetValueNames().Contains(i.ValueName, StringComparer.OrdinalIgnoreCase));
        }
        catch (Exception e) when (e is UnauthorizedAccessException or System.Security.SecurityException or IOException)
        {
            return true; // can't even read it: certainly not fixed
        }
    }

    public static string DefaultBackupName(DateTime now) => $"MakeCleaner_registry_{now:yyyyMMdd_HHmmss}.reg";

    public static void WriteBackup(IEnumerable<RegIssue> issues, string path)
    {
        var sb = new StringBuilder("Windows Registry Editor Version 5.00\r\n");
        foreach (var i in issues)
        {
            using var k = OpenKey(i.KeyPath, writable: false);
            if (k == null) continue;
            if (i.ValueName == null) ExportTree(k, sb);
            else if (k.GetValueNames().Contains(i.ValueName, StringComparer.OrdinalIgnoreCase))
                sb.Append($"\r\n[{k.Name}]\r\n").Append(ValueLine(k, i.ValueName)).Append("\r\n");
        }
        File.WriteAllText(path, sb.ToString(), Encoding.Unicode); // UTF-16LE + BOM, like regedit
    }

    static void ExportTree(RegistryKey k, StringBuilder sb)
    {
        sb.Append($"\r\n[{k.Name}]\r\n");
        foreach (var v in k.GetValueNames()) sb.Append(ValueLine(k, v)).Append("\r\n");
        foreach (var sub in k.GetSubKeyNames())
        {
            using var s = k.OpenSubKey(sub);
            if (s != null) ExportTree(s, sb);
        }
    }

    static string ValueLine(RegistryKey k, string name)
    {
        var lhs = name == "" ? "@" : $"\"{Esc(name)}\"";
        var kind = k.GetValueKind(name);
        var raw = k.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
        string rhs = (kind, raw) switch
        {
            (RegistryValueKind.String, string s) when !s.Contains('\r') && !s.Contains('\n') => $"\"{Esc(s)}\"",
            (RegistryValueKind.String, string s) => "hex(1):" + Hex(Utf16z(s)),
            (RegistryValueKind.DWord, int d) => $"dword:{(uint)d:x8}",
            (RegistryValueKind.QWord, long q) => "hex(b):" + Hex(BitConverter.GetBytes(q)),
            (RegistryValueKind.ExpandString, string s) => "hex(2):" + Hex(Utf16z(s)),
            (RegistryValueKind.MultiString, string[] m) => "hex(7):" + Hex(Utf16z(string.Concat(m.Select(x => x + "\0")))),
            (RegistryValueKind.Binary, byte[] b) => "hex:" + Hex(b),
            // REG_NONE. ponytail: .NET also folds exotic types (REG_LINK, REG_RESOURCE_LIST...) into Unknown
            // and hides their type id, so they round-trip as REG_NONE bytes.
            _ => "hex(0):" + Hex(raw as byte[] ?? []),
        };
        return $"{lhs}={rhs}";
    }

    static string Esc(string s) => s.Replace(@"\", @"\\").Replace("\"", "\\\"");
    static byte[] Utf16z(string s) => Encoding.Unicode.GetBytes(s + "\0");
    static string Hex(byte[] b) => string.Join(",", b.Select(x => x.ToString("x2")));

    static (string parent, string leaf) SplitParent(string path)
    {
        var i = path.LastIndexOf('\\');
        return (path[..i], path[(i + 1)..]);
    }

    public static RegistryKey? OpenKey(string fullPath, bool writable)
    {
        var i = fullPath.IndexOf('\\');
        var (hive, sub) = i < 0 ? (fullPath, "") : (fullPath[..i], fullPath[(i + 1)..]);
        RegistryKey root = hive.ToUpperInvariant() switch
        {
            "HKEY_CURRENT_USER" => Registry.CurrentUser,
            "HKEY_LOCAL_MACHINE" => Registry.LocalMachine,
            "HKEY_CLASSES_ROOT" => Registry.ClassesRoot,
            "HKEY_USERS" => Registry.Users,
            _ => throw new ArgumentException($"Unknown hive: {hive}"),
        };
        return sub == "" ? root : root.OpenSubKey(sub, writable);
    }
}
