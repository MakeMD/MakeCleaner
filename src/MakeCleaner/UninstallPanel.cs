namespace MakeCleaner;

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
