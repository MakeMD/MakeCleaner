using System.Diagnostics;

namespace MakeCleaner;

public record InstalledApp(string Name, string Publisher, string Version, string InstallDate, long SizeKb,
    string UninstallString, string ModifyPath, bool IsMsi, bool NoModify, bool NoRepair, string Key)
{
    string Code => Key[(Key.LastIndexOf('\\') + 1)..];
    public bool CanRepair => !NoRepair && (IsMsi || ModifyPath.Length > 0);
    public bool CanChange => !NoModify && (IsMsi || ModifyPath.Length > 0);
    public string? UninstallCommand => IsMsi ? $"msiexec.exe /x {Code}" : UninstallString.Length > 0 ? UninstallString : null;
    public string? RepairCommand => !CanRepair ? null : IsMsi ? $"msiexec.exe /fomus {Code}" : ModifyPath;
    public string? ChangeCommand => !CanChange ? null : IsMsi ? $"msiexec.exe /i {Code}" : ModifyPath;
}

public static class Uninstall
{
    public static readonly string[] Roots =
    [
        @"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        @"HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        @"HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall",
    ];

    // Same filter as "Programs and Features": named, not a system component, not an update/patch, has a way to uninstall.
    public static List<InstalledApp> Read(params string[] roots)
    {
        var apps = new List<InstalledApp>(); // no de-dup: ARP lists same-name entries separately too
        foreach (var root in roots)
            foreach (var name in Reg.SubKeys(root))
            {
                using var k = Reg.Open($@"{root}\{name}");
                if (k == null) continue;
                string S(string v) => (k.GetValue(v) as string)?.Trim() ?? "";
                bool B(string v) => k.GetValue(v) is int i && i == 1;
                var display = S("DisplayName");
                var release = S("ReleaseType");
                var isMsi = B("WindowsInstaller") && name.StartsWith('{');
                if (display.Length == 0 || B("SystemComponent") || S("ParentKeyName").Length > 0
                    || release is "Update" or "Hotfix" or "Security Update"
                    || (!isMsi && S("UninstallString").Length == 0)) continue;
                apps.Add(new InstalledApp(display, S("Publisher"), S("DisplayVersion"), S("InstallDate"),
                    k.GetValue("EstimatedSize") is int kb ? kb : 0, S("UninstallString"), S("ModifyPath"),
                    isMsi, B("NoModify"), B("NoRepair"), $@"{root}\{name}"));
            }
        return [.. apps.OrderBy(a => a.Name, StringComparer.CurrentCultureIgnoreCase)];
    }

    // "C:\a b\x.exe" /S  |  C:\a b\x.exe /S  |  MsiExec.exe /X{...}
    public static (string Exe, string Args) SplitCommand(string cmd)
    {
        cmd = Environment.ExpandEnvironmentVariables(cmd.Trim());
        int end;
        if (cmd.StartsWith('"'))
        {
            end = cmd.IndexOf('"', 1);
            if (end < 0) return (cmd.Trim('"'), "");
            return (cmd[1..end], cmd[(end + 1)..].Trim());
        }
        end = cmd.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
        end = end >= 0 ? end + 4 : cmd.IndexOf(' ');
        return end < 0 || end >= cmd.Length ? (cmd, "") : (cmd[..end], cmd[end..].Trim());
    }

    // Uninstallers carry their own elevation manifest; shell execute lets Windows show UAC when they need it.
    public static void Launch(string command)
    {
        var (exe, args) = SplitCommand(command);
        Process.Start(new ProcessStartInfo(exe, args) { UseShellExecute = true });
    }

    public static bool DeleteEntry(InstalledApp app) => Reg.DeleteKey(app.Key);
}
