using System.Runtime.InteropServices;
using System.Security.Principal;

namespace MakeCleaner;

// Something Clean will do that is not a file or registry entry (clipboard, DNS cache, event logs).
public record Pending(string Label, long Bytes, Func<bool> Run);

// Built-in procedures behind SpecialKey= in rules (things a FileKey/RegKey cannot express).
public static class Special
{
    public const string WipeFreeSpace = "WIPEFREESPACE"; // run by MainForm after Clean (needs passes + progress)

    // File procedures: their files go through the normal Clean path (secure delete, locked files skipped).
    public static readonly Dictionary<string, Func<Rule, IEnumerable<FileInfo>>> Files = new(StringComparer.OrdinalIgnoreCase)
    {
        ["RECYCLEBIN"] = r => RecycleBin(RecycleBinDirs(), r.OlderThanHours, DateTime.UtcNow),
        ["BROKENSTARTMENU"] = _ => BrokenShortcuts([Environment.GetFolderPath(Environment.SpecialFolder.StartMenu),
                                                    Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu)]),
        ["BROKENDESKTOP"] = _ => BrokenShortcuts([Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
                                                  Environment.GetFolderPath(Environment.SpecialFolder.CommonDesktopDirectory)]),
    };

    // Action procedures: Analyze only describes them, Clean runs them. null = nothing to do.
    public static readonly Dictionary<string, Func<Pending?>> Actions = new(StringComparer.OrdinalIgnoreCase)
    {
        ["CLIPBOARD"] = () => CountClipboardFormats() > 0 ? new("Clipboard contents", 0, EmptyClipboardNow) : null,
        ["DNSCACHE"] = () => new("DNS resolver cache", 0, () => DnsFlushResolverCache()),
        ["EVENTLOGS"] = EventLogs,
    };

    // ---- Recycle Bin: X:\$Recycle.Bin\<user SID>\$Ixxxx (metadata) + $Rxxxx (file or folder) ----

    static IEnumerable<string> RecycleBinDirs()
    {
        var sid = WindowsIdentity.GetCurrent().User?.Value;
        if (sid == null) return [];
        return DriveInfo.GetDrives().Where(d => d.DriveType == DriveType.Fixed && d.IsReady)
            .Select(d => Path.Combine(d.RootDirectory.FullName, "$Recycle.Bin", sid));
    }

    // olderThanHours: only items deleted at least that long ago (deletion time = FILETIME at offset 16 of $I).
    public static IEnumerable<FileInfo> RecycleBin(IEnumerable<string> binDirs, int? olderThanHours, DateTime nowUtc)
    {
        var opts = new EnumerationOptions { IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint, RecurseSubdirectories = true };
        foreach (var dir in binDirs.Where(Directory.Exists))
        {
            FileInfo[] meta;
            try { meta = new DirectoryInfo(dir).GetFiles("$I*"); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { continue; }
            foreach (var i in meta)
            {
                if (olderThanHours is int h && DeletedUtc(i) is { } deleted && nowUtc - deleted < TimeSpan.FromHours(h)) continue;
                yield return i;
                var r = Path.Combine(dir, "$R" + i.Name[2..]);
                if (File.Exists(r)) yield return new FileInfo(r);
                else if (Directory.Exists(r))
                    foreach (var f in new DirectoryInfo(r).EnumerateFiles("*", opts)) yield return f;
            }
        }
    }

    static DateTime? DeletedUtc(FileInfo meta)
    {
        try
        {
            using var s = meta.OpenRead();
            var b = new byte[24];
            if (s.Read(b, 0, 24) < 24) return null;
            return DateTime.FromFileTimeUtc(BitConverter.ToInt64(b, 16));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentOutOfRangeException) { return null; }
    }

    // After Clean: the $R folders of deleted items are empty now; drop them and refresh the bin icon.
    public static void AfterClean(Rule rule)
    {
        if (!rule.SpecialKeys.Contains("RECYCLEBIN", StringComparer.OrdinalIgnoreCase)) return;
        foreach (var dir in RecycleBinDirs().Where(Directory.Exists))
            foreach (var r in Directory.EnumerateDirectories(dir, "$R*"))
                try
                {
                    if (!Directory.EnumerateFiles(r, "*", SearchOption.AllDirectories).Any()) Directory.Delete(r, true);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        SHUpdateRecycleBinIcon();
    }

    // ---- Broken shortcuts: .lnk whose target is a missing path on a ready local fixed drive ----
    // Network, removable and shell-item targets (no file path) are never treated as broken.

    public static IEnumerable<FileInfo> BrokenShortcuts(IEnumerable<string> folders)
    {
        var shellType = Type.GetTypeFromProgID("WScript.Shell");
        if (shellType == null) yield break;
        dynamic shell = Activator.CreateInstance(shellType)!;
        var opts = new EnumerationOptions { IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint, RecurseSubdirectories = true };
        foreach (var folder in folders.Where(f => f.Length > 0 && Directory.Exists(f)).Distinct(StringComparer.OrdinalIgnoreCase))
            foreach (var lnk in new DirectoryInfo(folder).EnumerateFiles("*.lnk", opts))
            {
                string target;
                try { target = (string)shell.CreateShortcut(lnk.FullName).TargetPath; }
                catch (COMException) { continue; }
                if (IsBrokenTarget(target)) yield return lnk;
            }
    }

    static bool IsBrokenTarget(string target)
    {
        if (target.Length == 0 || !Path.IsPathFullyQualified(target) || target.StartsWith(@"\\")) return false;
        try
        {
            var drive = new DriveInfo(Path.GetPathRoot(target)!);
            return drive.DriveType == DriveType.Fixed && drive.IsReady && !Path.Exists(target);
        }
        catch (ArgumentException) { return false; }
    }

    // ---- Event logs: one elevated wevtutil loop, UAC only when Clean runs ----

    static Pending EventLogs()
    {
        var dir = Path.Combine(Environment.SystemDirectory, "winevt", "Logs");
        long bytes = 0;
        try
        {
            bytes = new DirectoryInfo(dir).EnumerateFiles("*.evtx", new EnumerationOptions { IgnoreInaccessible = true }).Sum(f => f.Length);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { } // size unknown without admin
        return new("Windows event logs (all)", bytes,
            () => Elevated.Run("cmd.exe", "/c for /f \"delims=\" %l in ('wevtutil el') do @wevtutil cl \"%l\""));
    }

    // ---- Win32 ----

    static bool EmptyClipboardNow()
    {
        if (!OpenClipboard(IntPtr.Zero)) return false;
        try { return EmptyClipboard(); }
        finally { CloseClipboard(); }
    }

    [DllImport("user32.dll")] static extern int CountClipboardFormats();
    [DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll")] static extern bool EmptyClipboard();
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    // Clears the local resolver cache only (same as ipconfig /flushdns); sends nothing over the network.
    [DllImport("dnsapi.dll")] static extern bool DnsFlushResolverCache();
    [DllImport("shell32.dll")] static extern void SHUpdateRecycleBinIcon();
}
