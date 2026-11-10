using System.Runtime.InteropServices;
using System.Text;

namespace MakeCleaner;

public enum StartupKind { Run, Folder, Task, ContextMenu, Service }

// Location: Run = run key, Folder = file path, Task = task path, ContextMenu = handler key, Service = service key.
// Approved: StartupApproved key (Run/Folder) or Shell Extensions\Blocked key (ContextMenu). Id: CLSID or service name.
public record StartupItem(StartupKind Kind, string Name, string Command, bool Enabled, string Location,
    string Approved = "", string Id = "", string Info = "");

public static class Startup
{
    const string Cv = @"SOFTWARE\Microsoft\Windows\CurrentVersion";
    const string Approved = $@"{Cv}\Explorer\StartupApproved";
    public const string BlockedKey = $@"HKLM\{Cv}\Shell Extensions\Blocked";
    public const string ServicesKey = @"HKLM\SYSTEM\CurrentControlSet\Services";
    public const string PrevStartValue = "MakeCleanerPrevStart";

    public static readonly (string Run, string Approved)[] RunKeys =
    [
        ($@"HKCU\{Cv}\Run", $@"HKCU\{Approved}\Run"),
        ($@"HKLM\{Cv}\Run", $@"HKLM\{Approved}\Run"),
        (@"HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run", $@"HKLM\{Approved}\Run32"),
    ];

    public static readonly (string Folder, string Approved)[] Folders =
    [
        (Environment.GetFolderPath(Environment.SpecialFolder.Startup), $@"HKCU\{Approved}\StartupFolder"),
        (Environment.GetFolderPath(Environment.SpecialFolder.CommonStartup), $@"HKLM\{Approved}\StartupFolder"),
    ];

    public static readonly string[] ShellexTypes = ["*", "AllFilesystemObjects", "Directory", @"Directory\Background", "Folder", "Drive"];

    // StartupApproved value, as Task Manager writes it: 12 bytes, low bit of byte 0 set = disabled, then FILETIME of disabling.
    public static bool IsApproved(byte[]? v) => v is not { Length: > 0 } || (v[0] & 1) == 0;

    public static byte[] ApprovedBytes(bool enabled, DateTime utcNow)
    {
        var b = new byte[12];
        b[0] = enabled ? (byte)2 : (byte)3;
        if (!enabled) BitConverter.GetBytes(utcNow.ToFileTimeUtc()).CopyTo(b, 4);
        return b;
    }

    static byte[]? ApprovedValue(string key, string name)
    {
        using var k = Reg.Open(key);
        return k?.GetValue(name) as byte[];
    }

    public static IEnumerable<StartupItem> ReadRun(string runKey, string approvedKey)
    {
        using var k = Reg.Open(runKey);
        if (k == null) yield break;
        foreach (var name in k.GetValueNames().Where(n => n.Length > 0))
            yield return new(StartupKind.Run, name, k.GetValue(name)?.ToString() ?? "",
                IsApproved(ApprovedValue(approvedKey, name)), runKey, approvedKey);
    }

    public static IEnumerable<StartupItem> ReadFolder(string folder, string approvedKey)
    {
        if (folder.Length == 0 || !Directory.Exists(folder)) yield break;
        foreach (var f in Directory.EnumerateFiles(folder).Where(f => !Path.GetFileName(f).Equals("desktop.ini", StringComparison.OrdinalIgnoreCase)))
        {
            var name = Path.GetFileName(f);
            yield return new(StartupKind.Folder, name, f, IsApproved(ApprovedValue(approvedKey, name)), f, approvedKey);
        }
    }

    // classesRoot is "HKCR" in production, a test key in tests.
    public static IEnumerable<StartupItem> ReadContextMenu(string classesRoot, string blockedKey)
    {
        using var blocked = Reg.Open(blockedKey);
        var blockedIds = new HashSet<string>(blocked?.GetValueNames() ?? [], StringComparer.OrdinalIgnoreCase);
        foreach (var type in ShellexTypes)
        {
            var handlers = $@"{classesRoot}\{type}\shellex\ContextMenuHandlers";
            foreach (var name in Reg.SubKeys(handlers))
            {
                using var k = Reg.Open($@"{handlers}\{name}");
                var clsid = name.StartsWith('{') ? name : (k?.GetValue("") as string ?? "").Trim();
                using var cls = clsid.Length > 0 ? Reg.Open($@"{classesRoot}\CLSID\{clsid}") : null;
                using var server = clsid.Length > 0 ? Reg.Open($@"{classesRoot}\CLSID\{clsid}\InprocServer32") : null;
                var label = cls?.GetValue("") as string;
                yield return new(StartupKind.ContextMenu, string.IsNullOrWhiteSpace(label) ? name : label,
                    server?.GetValue("") as string ?? "", !blockedIds.Contains(clsid), $@"{handlers}\{name}", blockedKey, clsid, type);
            }
        }
    }

    // Win32 services only: no drivers, no per-user service templates/instances.
    public static IEnumerable<StartupItem> ReadServices(string servicesKey)
    {
        foreach (var name in Reg.SubKeys(servicesKey))
        {
            using var k = Reg.Open($@"{servicesKey}\{name}");
            if (k?.GetValue("Type") is not int type || (type & 0x30) == 0 || (type & 0xC0) != 0) continue;
            if (k.GetValue("Start") is not int start || start < 2) continue;
            var display = k.GetValue("DisplayName") as string ?? name;
            var info = start switch
            {
                2 => k.GetValue("DelayedAutostart") is 1 ? "Auto (delayed)" : "Auto",
                3 => "Manual",
                _ => "Disabled",
            };
            yield return new(StartupKind.Service, Indirect(display), k.GetValue("ImagePath") as string ?? "",
                start != 4, $@"{servicesKey}\{name}", Id: name, Info: info);
        }
    }

    // Non-Microsoft scheduled tasks through the Task Scheduler COM API (no schtasks text parsing: its headers are localized).
    public static List<StartupItem> ReadTasks()
    {
        var items = new List<StartupItem>();
        dynamic svc = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service")!)!;
        svc.Connect();
        void Walk(dynamic folder)
        {
            if (((string)folder.Path).StartsWith(@"\Microsoft", StringComparison.OrdinalIgnoreCase)) return;
            foreach (dynamic t in folder.GetTasks(1)) // 1 = include hidden
            {
                var cmd = "";
                try
                {
                    foreach (dynamic a in t.Definition.Actions)
                        if ((int)a.Type == 0) { cmd = $"{a.Path} {a.Arguments}".Trim(); break; }
                }
                catch (COMException) { } // definition not readable without admin
                items.Add(new(StartupKind.Task, (string)t.Name, cmd, (bool)t.Enabled, (string)t.Path));
            }
            foreach (dynamic f in folder.GetFolders(0)) Walk(f);
        }
        Walk(svc.GetFolder(@"\"));
        return items;
    }

    public static List<StartupItem> ReadWindows() =>
        [.. RunKeys.SelectMany(r => ReadRun(r.Run, r.Approved)), .. Folders.SelectMany(f => ReadFolder(f.Folder, f.Approved))];

    public static bool SetEnabled(StartupItem it, bool on) => it.Kind switch
    {
        StartupKind.Run or StartupKind.Folder => Reg.SetBinary(it.Approved, it.Name, ApprovedBytes(on, DateTime.UtcNow)),
        StartupKind.ContextMenu => on ? Reg.DeleteValue(it.Approved, it.Id) : Reg.SetString(it.Approved, it.Id, ""),
        StartupKind.Task => TaskAction(it.Location, t => t.Enabled = on, $"/change /tn \"{it.Location}\" /{(on ? "enable" : "disable")}"),
        StartupKind.Service => Elevated.Run("cmd.exe", ServiceToggleArgs(it, on)),
        _ => false,
    };

    // ponytail: Windows has no "previous start type"; we keep it in a value inside the service's own key.
    public static string ServiceToggleArgs(StartupItem it, bool on)
    {
        var key = $@"HKLM\SYSTEM\CurrentControlSet\Services\{it.Id}";
        if (!on)
        {
            var prev = it.Info == "Manual" ? 3 : 2;
            return $"/c sc config \"{it.Id}\" start= disabled & reg add \"{key}\" /v {PrevStartValue} /t REG_DWORD /d {prev} /f";
        }
        using var k = Reg.Open(it.Location);
        var start = k?.GetValue(PrevStartValue) is 2 ? (k.GetValue("DelayedAutostart") is 1 ? "delayed-auto" : "auto") : "demand";
        return $"/c sc config \"{it.Id}\" start= {start} & reg delete \"{key}\" /v {PrevStartValue} /f";
    }

    public static bool IsSystemService(StartupItem it) =>
        it.Command.Contains(Environment.GetFolderPath(Environment.SpecialFolder.Windows), StringComparison.OrdinalIgnoreCase)
        || it.Command.Contains(@"\Windows\", StringComparison.OrdinalIgnoreCase)
        || it.Command.Contains("system32", StringComparison.OrdinalIgnoreCase);

    public static bool Delete(StartupItem it)
    {
        bool DropApproved() => ApprovedValue(it.Approved, it.Name) == null || Reg.DeleteValue(it.Approved, it.Name);
        switch (it.Kind)
        {
            case StartupKind.Run:
                return Reg.DeleteValue(it.Location, it.Name) && DropApproved();
            case StartupKind.Folder:
                return Elevated.Try(() => File.Delete(it.Location), "cmd.exe", $"/c del /f /q \"{it.Location}\"") && DropApproved();
            case StartupKind.ContextMenu:
                return Reg.DeleteKey(it.Location) && (it.Enabled || Reg.DeleteValue(it.Approved, it.Id));
            case StartupKind.Task:
                var i = it.Location.LastIndexOf('\\');
                var parent = i <= 0 ? @"\" : it.Location[..i];
                return TaskAction(parent, f => f.DeleteTask(it.Location[(i + 1)..], 0), $"/delete /tn \"{it.Location}\" /f", folder: true);
            case StartupKind.Service:
                return !IsSystemService(it) && Elevated.Run("sc.exe", $"delete \"{it.Id}\"");
            default:
                return false;
        }
    }

    // Direct COM first; access denied -> elevated schtasks.exe.
    static bool TaskAction(string path, Action<dynamic> act, string schtasksArgs, bool folder = false) => Elevated.Try(() =>
    {
        try
        {
            dynamic svc = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service")!)!;
            svc.Connect();
            act(folder ? svc.GetFolder(path) : svc.GetFolder(@"\").GetTask(path));
        }
        catch (COMException e) when (e.HResult == unchecked((int)0x80070005)) { throw new UnauthorizedAccessException(e.Message, e); }
    }, "schtasks.exe", schtasksArgs);

    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
    static extern int SHLoadIndirectString(string source, StringBuilder buf, int size, IntPtr reserved);

    // "@%SystemRoot%\system32\x.dll,-100" -> localized name
    static string Indirect(string s)
    {
        if (!s.StartsWith('@')) return s;
        var sb = new StringBuilder(512);
        return SHLoadIndirectString(s, sb, sb.Capacity, IntPtr.Zero) == 0 ? sb.ToString() : s;
    }
}
