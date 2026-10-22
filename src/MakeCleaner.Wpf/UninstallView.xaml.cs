using System.Windows.Controls;

namespace MakeCleaner;

public partial class UninstallView : UserControl
{
    public record Row(string Name, string Publisher, string Date, string Size, string Version, InstalledApp App);
    List<InstalledApp> apps = [];

    public UninstallView()
    {
        InitializeComponent();
        search.TextChanged += (_, _) => Fill();
        list.SelectionChanged += (_, _) => UpdateButtons();
        uninstall.Click += (_, _) => Run(a => a.UninstallCommand);
        repair.Click += (_, _) => Run(a => a.RepairCommand);
        change.Click += (_, _) => Run(a => a.ChangeCommand);
        refresh.Click += async (_, _) => await Reload();
        delete.Click += async (_, _) =>
        {
            if (Selected is not { } a || !ToolsUi.Confirm(this,
                    $"Remove \"{a.Name}\" from the list?\nOnly the registry entry is deleted, the program files stay.", "Delete entry")) return;
            if (!Uninstall.DeleteEntry(a)) ToolsUi.Info(this, "The entry was not deleted.", "Delete entry");
            await Reload();
        };
        save.Click += (_, _) => ToolsUi.SaveText(this, "programs",
            ["Program\tPublisher\tInstalled On\tSize\tVersion",
             .. list.Items.Cast<Row>().Select(r => string.Join('\t', r.Name, r.Publisher, r.Date, r.Size, r.Version))]);
        UpdateButtons();
        // not from the constructor: the first sub-page is built inside MainWindow's constructor, before the dispatcher
        // runs, so an await there would resume off the UI thread
        Loaded += async (_, _) => { if (!loaded) { loaded = true; await Reload(); } };
    }

    bool loaded;

    InstalledApp? Selected => (list.SelectedItem as Row)?.App;

    async Task Reload()
    {
        try { apps = await Task.Run(() => Uninstall.Read(Uninstall.Roots)); }
        catch (Exception e) { apps = []; Fill(); count.Text = "Error: " + e.Message; return; }
        Fill();
    }

    void Fill()
    {
        var q = search.Text.Trim();
        list.ItemsSource = apps
            .Where(a => q.Length == 0 || a.Name.Contains(q, StringComparison.CurrentCultureIgnoreCase)
                        || a.Publisher.Contains(q, StringComparison.CurrentCultureIgnoreCase))
            .Select(a => new Row(a.Name, a.Publisher, FmtDate(a.InstallDate), a.SizeKb > 0 ? $"{a.SizeKb / 1024.0:0.#} MB" : "", a.Version, a))
            .ToList();
        count.Text = $"{list.Items.Count} programs";
        UpdateButtons();
    }

    void UpdateButtons()
    {
        var a = Selected;
        uninstall.IsEnabled = a?.UninstallCommand != null;
        repair.IsEnabled = a?.RepairCommand != null;
        change.IsEnabled = a?.ChangeCommand != null;
        delete.IsEnabled = a != null;
    }

    void Run(Func<InstalledApp, string?> command)
    {
        if (Selected is not { } a || command(a) is not { } cmd) return;
        try { Uninstall.Launch(cmd); }
        catch (Exception e) { ToolsUi.Info(this, e.Message, a.Name); }
    }

    static string FmtDate(string d) =>
        DateTime.TryParseExact(d, "yyyyMMdd", null, System.Globalization.DateTimeStyles.None, out var t) ? t.ToShortDateString() : d;
}
