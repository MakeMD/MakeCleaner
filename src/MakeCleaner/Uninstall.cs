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

public class UninstallPanel : UserControl
{
    readonly TextBox search = new() { Dock = DockStyle.Top, PlaceholderText = "Search", Name = "uninstallSearch" };
    readonly ListView list = new() { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, MultiSelect = false, Name = "uninstallList" };
    readonly Button uninstall = new() { Text = "Run Uninstaller", Width = 120 };
    readonly Button repair = new() { Text = "Repair", Width = 90 };
    readonly Button change = new() { Text = "Change", Width = 90 };
    readonly Button delete = new() { Text = "Delete entry", Width = 100 };
    readonly Button refresh = new() { Text = "Refresh", Width = 90 };
    List<InstalledApp> apps = [];

    public UninstallPanel()
    {
        foreach (var (h, w) in new[] { ("Program", 320), ("Publisher", 200), ("Installed On", 90), ("Size", 80), ("Version", 110) })
            list.Columns.Add(h, w);
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Right, Width = 130, FlowDirection = FlowDirection.TopDown };
        buttons.Controls.AddRange([uninstall, repair, change, delete, refresh]);
        Controls.AddRange([list, search, buttons]);

        search.TextChanged += (_, _) => Fill();
        list.SelectedIndexChanged += (_, _) => UpdateButtons();
        uninstall.Click += (_, _) => Run(a => a.UninstallCommand);
        repair.Click += (_, _) => Run(a => a.RepairCommand);
        change.Click += (_, _) => Run(a => a.ChangeCommand);
        refresh.Click += async (_, _) => await Reload();
        delete.Click += async (_, _) =>
        {
            if (Selected is not { } a || MessageBox.Show(this,
                $"Remove \"{a.Name}\" from the list?\nOnly the registry entry is deleted, the program files stay.",
                "Delete entry", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
            if (!Uninstall.DeleteEntry(a)) MessageBox.Show(this, "The entry was not deleted.", "Delete entry");
            await Reload();
        };
        Load += async (_, _) => await Reload();
        UpdateButtons();
    }

    InstalledApp? Selected => list.SelectedItems.Count == 1 ? (InstalledApp)list.SelectedItems[0].Tag! : null;

    async Task Reload()
    {
        apps = await Task.Run(() => Uninstall.Read(Uninstall.Roots));
        Fill();
    }

    void Fill()
    {
        var q = search.Text.Trim();
        list.BeginUpdate();
        list.Items.Clear();
        foreach (var a in apps.Where(a => q.Length == 0 || a.Name.Contains(q, StringComparison.CurrentCultureIgnoreCase)
                                          || a.Publisher.Contains(q, StringComparison.CurrentCultureIgnoreCase)))
            list.Items.Add(new ListViewItem([a.Name, a.Publisher, FmtDate(a.InstallDate), a.SizeKb > 0 ? $"{a.SizeKb / 1024.0:0.#} MB" : "", a.Version]) { Tag = a });
        list.EndUpdate();
        UpdateButtons();
    }

    void UpdateButtons()
    {
        var a = Selected;
        uninstall.Enabled = a?.UninstallCommand != null;
        repair.Enabled = a?.RepairCommand != null;
        change.Enabled = a?.ChangeCommand != null;
        delete.Enabled = a != null;
    }

    void Run(Func<InstalledApp, string?> command)
    {
        if (Selected is not { } a || command(a) is not { } cmd) return;
        try { Uninstall.Launch(cmd); }
        catch (Exception e) { MessageBox.Show(this, e.Message, a.Name); }
    }

    static string FmtDate(string d) =>
        DateTime.TryParseExact(d, "yyyyMMdd", null, System.Globalization.DateTimeStyles.None, out var t) ? t.ToShortDateString() : d;
}
