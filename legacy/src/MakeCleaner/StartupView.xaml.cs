using System.Windows.Controls;
using System.Windows.Automation;

namespace MakeCleaner;

public partial class StartupView : UserControl
{
    public record Row(string Enabled, string Name, string Location, string Command, StartupItem? Item);

    readonly (string Title, Func<List<StartupItem>> Read, ListView List)[] pages =
    [
        ("Windows", Startup.ReadWindows, NewList("startupWindows")),
        ("Scheduled Tasks", Startup.ReadTasks, NewList("startupTasks")),
        ("Context Menu", () => [.. Startup.ReadContextMenu("HKCR", Startup.BlockedKey)], NewList("startupContext")),
        ("Windows Services", () => [.. Startup.ReadServices(Startup.ServicesKey)], NewList("startupServices")),
    ];

    static ListView NewList(string id)
    {
        var view = new GridView();
        foreach (var (h, w, p) in new[] { ("Enabled", 80, "Enabled"), ("Name", 230, "Name"), ("Location", 250, "Location"), ("Command", 380, "Command") })
            view.Columns.Add(new GridViewColumn { Header = h, Width = w, DisplayMemberBinding = new System.Windows.Data.Binding(p) });
        var l = new ListView { View = view, SelectionMode = SelectionMode.Single, BorderThickness = new System.Windows.Thickness(0) };
        VirtualizingPanel.SetIsVirtualizing(l, false); // ~300 services at most; UI Automation sees every row
        AutomationProperties.SetAutomationId(l, id);
        return l;
    }

    public StartupView()
    {
        InitializeComponent();
        foreach (var p in pages)
        {
            tabs.Items.Add(new TabItem { Header = p.Title, Content = p.List });
            p.List.SelectionChanged += (_, _) => UpdateButtons();
        }
        tabs.SelectedIndex = 0;
        tabs.SelectionChanged += (_, e) => { if (e.Source == tabs) UpdateButtons(); }; // list selections bubble up too
        enable.Click += async (_, _) => await Act(it => Startup.SetEnabled(it, true));
        disable.Click += async (_, _) => await Act(it => Startup.SetEnabled(it, false));
        delete.Click += async (_, _) => await Act(Startup.Delete, confirm: true);
        refresh.Click += async (_, _) => await Reload();
        save.Click += (_, _) =>
        {
            var (title, _, list) = pages[tabs.SelectedIndex];
            ToolsUi.SaveText(this, "startup " + title, ["Enabled\tName\tLocation\tCommand",
                .. list.Items.Cast<Row>().Select(r => string.Join('\t', r.Enabled, r.Name, r.Location, r.Command))]);
        };
        UpdateButtons();
        Loaded += async (_, _) => { if (!loaded) { loaded = true; await Reload(); } }; // see UninstallView: never await in the constructor
    }

    bool loaded;

    ListView Current => pages[Math.Max(0, tabs.SelectedIndex)].List;
    StartupItem? Selected => (Current.SelectedItem as Row)?.Item;

    async Task Reload()
    {
        foreach (var p in pages)
        {
            try
            {
                var items = await Task.Run(p.Read);
                p.List.ItemsSource = items.Select(it => new Row(it.Info.Length > 0 ? it.Info : it.Enabled ? "Yes" : "No", it.Name, it.Location, it.Command, it)).ToList();
            }
            catch (Exception e) { p.List.ItemsSource = new List<Row> { new("", $"Error: {e.Message}", "", "", null) }; }
        }
        UpdateButtons();
    }

    void UpdateButtons()
    {
        var it = Selected;
        enable.IsEnabled = it is { Enabled: false };
        disable.IsEnabled = it is { Enabled: true };
        delete.IsEnabled = it != null && !(it.Kind == StartupKind.Service && Startup.IsSystemService(it));
    }

    async Task Act(Func<StartupItem, bool> action, bool confirm = false)
    {
        if (Selected is not { } it) return;
        if (confirm && !ToolsUi.Confirm(this, $"Delete \"{it.Name}\"?\nThis cannot be undone.", "Delete")) return;
        if (!await Task.Run(() => action(it))) ToolsUi.Info(this, "The change was not applied.", it.Name);
        await Reload();
    }
}
