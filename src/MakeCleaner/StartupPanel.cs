namespace MakeCleaner;

public class StartupPanel : UserControl
{
    readonly TabControl tabs = new() { Dock = DockStyle.Fill, Name = "startupTabs" };
    readonly (string Title, Func<List<StartupItem>> Read, ListView List)[] pages =
    [
        ("Windows", Startup.ReadWindows, NewList("startupWindows")),
        ("Scheduled Tasks", Startup.ReadTasks, NewList("startupTasks")),
        ("Context Menu", () => [.. Startup.ReadContextMenu("HKCR", Startup.BlockedKey)], NewList("startupContext")),
        ("Windows Services", () => [.. Startup.ReadServices(Startup.ServicesKey)], NewList("startupServices")),
    ];
    readonly Button enable = new() { Text = "Enable", Width = 100 };
    readonly Button disable = new() { Text = "Disable", Width = 100 };
    readonly Button delete = new() { Text = "Delete", Width = 100 };
    readonly Button refresh = new() { Text = "Refresh", Width = 100 };

    static ListView NewList(string name)
    {
        var l = new ListView { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, MultiSelect = false, Name = name };
        foreach (var (h, w) in new[] { ("Enabled", 90), ("Name", 240), ("Location", 260), ("Command", 400) }) l.Columns.Add(h, w);
        return l;
    }

    public StartupPanel()
    {
        foreach (var p in pages)
        {
            tabs.TabPages.Add(ToolsPanel.Page(p.Title, p.List));
            p.List.SelectedIndexChanged += (_, _) => UpdateButtons();
        }
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Right, Width = 110, FlowDirection = FlowDirection.TopDown };
        buttons.Controls.AddRange([enable, disable, delete, refresh]);
        Controls.AddRange([tabs, buttons]);

        tabs.SelectedIndexChanged += (_, _) => UpdateButtons();
        enable.Click += async (_, _) => await Act(it => Startup.SetEnabled(it, true));
        disable.Click += async (_, _) => await Act(it => Startup.SetEnabled(it, false));
        delete.Click += async (_, _) => await Act(Startup.Delete, confirm: true);
        refresh.Click += async (_, _) => await Reload();
        Load += async (_, _) => await Reload();
        UpdateButtons();
    }

    ListView Current => pages[Math.Max(0, tabs.SelectedIndex)].List; // -1 until the tab control has a handle
    StartupItem? Selected => Current.SelectedItems.Count == 1 ? (StartupItem)Current.SelectedItems[0].Tag! : null;

    async Task Reload()
    {
        foreach (var p in pages)
        {
            List<StartupItem> items;
            try { items = await Task.Run(p.Read); }
            catch (Exception e) { items = []; p.List.Items.Clear(); p.List.Items.Add($"Error: {e.Message}"); continue; }
            p.List.BeginUpdate();
            p.List.Items.Clear();
            foreach (var it in items)
                p.List.Items.Add(new ListViewItem([it.Info.Length > 0 ? it.Info : it.Enabled ? "Yes" : "No", it.Name, it.Location, it.Command]) { Tag = it });
            p.List.EndUpdate();
        }
        UpdateButtons();
    }

    void UpdateButtons()
    {
        var it = Selected;
        enable.Enabled = it is { Enabled: false };
        disable.Enabled = it is { Enabled: true };
        delete.Enabled = it != null && !(it.Kind == StartupKind.Service && Startup.IsSystemService(it));
    }

    async Task Act(Func<StartupItem, bool> action, bool confirm = false)
    {
        if (Selected is not { } it) return;
        if (confirm && MessageBox.Show(this, $"Delete \"{it.Name}\"?\nThis cannot be undone.", "Delete",
                MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
        if (!await Task.Run(() => action(it))) MessageBox.Show(this, "The change was not applied.", it.Name);
        await Reload();
    }
}
