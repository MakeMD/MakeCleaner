using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace MakeCleaner;

// Cleaner: Windows / Browsers / Applications check trees -> Analyze (progress, Cancel) -> results -> Run Cleaner.
// All cleaning goes through CleanPass, the same pass /auto runs.
public partial class CleanerView : UserControl
{
    // One results line; Path is set for a file (context menu: open folder, exclude).
    public record Line(string Name, string Found, string Size, string? Path = null);

    const int MaxFileLines = 5000; // ponytail: a plain ListView; Summary holds the totals when there are more files

    readonly Settings settings;
    readonly CleanPass pass;
    readonly List<CheckNode> windowGroups;
    List<CheckNode> browserGroups = [], appGroups = [];
    CancellationTokenSource? cts;
    bool listsLoading;

    public CleanerView(Settings settings)
    {
        InitializeComponent();
        this.settings = settings;
        pass = new CleanPass(settings);
        windows.ItemsSource = windowGroups = Groups(CleanPass.WindowsRules(), expanded: true);
        status.Text = "Detecting installed applications...";

        analyze.Click += async (_, _) => await RunAnalyze();
        clean.Click += async (_, _) => await RunClean();
        cancel.Click += (_, _) => { cts?.Cancel(); status.Text = "Cancelling..."; };
        results.SizeChanged += (_, _) => // the Item column takes whatever Found and Size leave
        {
            var cols = ((GridView)results.View).Columns;
            cols[0].Width = Math.Max(150, results.ActualWidth - cols[1].Width - cols[2].Width - 32);
        };
        viewSummary.Checked += (_, _) => ShowResults();
        viewFiles.Checked += (_, _) => ShowResults();
        results.ContextMenuOpening += (_, _) =>
        {
            var file = results.SelectedItem is Line { Path: not null };
            openFolder.IsEnabled = excludeFile.IsEnabled = excludeFolder.IsEnabled = file;
        };
        openFolder.Click += (_, _) =>
        {
            if (results.SelectedItem is Line { Path: { } p }) Process.Start("explorer.exe", $"/select,\"{p}\"");
        };
        excludeFile.Click += (_, _) => Exclude(folder: false);
        excludeFolder.Click += (_, _) => Exclude(folder: true);
        Loaded += async (_, _) =>
        {
            if (listsLoading) return; // Loaded fires again every time the rail comes back to Cleaner
            listsLoading = true;
            await LoadLists();
        };
    }

    List<CheckNode> Groups(IEnumerable<Rule> rules, bool expanded) =>
        [.. rules.GroupBy(r => r.Group).Select(g => CheckNode.Group(g.Key,
            g.Select(r => new CheckNode(r.Name, r, r.Warning, settings.GetBool(r.Name, r.Default))), expanded))];

    async Task LoadLists()
    {
        var found = await Task.Run(() => Browsers.Detect());
        browsers.ItemsSource = browserGroups = [.. found.GroupBy(i => i.Browser).Select(g => CheckNode.Group(g.Key,
            g.Select(i => new CheckNode(i.Name, i, i.Warning, settings.GetBool(i.Key, i.Default))), expanded: true))];
        var list = await Task.Run(CleanPass.AppRules);
        apps.ItemsSource = appGroups = Groups(list, expanded: false);
        // an Analyze/Clean started meanwhile owns the status line; don't overwrite its result
        if (status.Text.StartsWith("Detecting", StringComparison.Ordinal)) status.Text = $"{list.Count} applications detected";
    }

    List<Rule> CheckedRules() =>
        [.. CheckNode.Items(windowGroups.Concat(appGroups)).Where(n => n.IsChecked == true).Select(n => (Rule)n.Tag!)];
    List<BrowserItem> CheckedBrowserItems() =>
        [.. CheckNode.Items(browserGroups).Where(n => n.IsChecked == true).Select(n => (BrowserItem)n.Tag!)];

    async Task RunAnalyze()
    {
        SetBusy(true, "Analyzing...");
        var (rules, items) = (CheckedRules(), CheckedBrowserItems());
        cts = new CancellationTokenSource();
        var token = cts.Token;
        var report = new Progress<(int Done, int Total)>(p =>
        {
            if (cts == null) return; // a late report after the run ended
            progress.Maximum = Math.Max(1, p.Total);
            progress.Value = p.Done;
            progressText.Text = p.Total == 0 ? "" : $"{p.Done * 100 / p.Total}% ({p.Done} of {p.Total})";
        });
        cancel.IsEnabled = true;
        string text;
        try
        {
            await Task.Run(() => pass.Analyze(rules, items, report, token));
            text = pass.AnalyzeSummary();
        }
        catch (OperationCanceledException)
        {
            text = "Analysis cancelled. Nothing will be cleaned.";
            progress.Value = 0;
            progressText.Text = "";
        }
        finally
        {
            cancel.IsEnabled = false;
            cts.Dispose();
            cts = null;
        }
        ShowResults();
        SetBusy(false, text);
        clean.IsEnabled = pass.Any;
    }

    async Task RunClean()
    {
        var skip = AskAboutRunningBrowsers();
        if (skip == null) return;
        SetBusy(true, "Cleaning...");
        var wipe = new Progress<string>(s => status.Text = "Wiping free space... " + s);
        var summary = await Task.Run(() => pass.Clean(skip, wipe));
        ShowResults();
        SetBusy(false, summary);
    }

    // Running browser: close it gracefully (no kill) or leave its items out of this clean. null = user cancelled.
    HashSet<string>? AskAboutRunningBrowsers()
    {
        var owner = Window.GetWindow(this);
        var skipped = new HashSet<string>();
        foreach (var b in pass.RunningBrowsers())
        {
            var answer = Dialog.Show(owner, b.Name, $"{b.Name} is running, so its files are locked. Close it now, or leave it out of this clean?",
                DialogKind.Question, $"Close {b.Name}", "Skip", "Cancel");
            if (answer is 2 or -1) return null;
            if (answer == 0 && Browsers.CloseGracefully(b.Running())) continue;
            if (answer == 0) Dialog.Info(owner, b.Name, $"{b.Name} did not close (maybe an unsaved dialog). Skipping it.");
            skipped.Add(b.Name);
        }
        return skipped;
    }

    void ShowResults()
    {
        List<Line> lines = viewFiles.IsChecked == true ? FileLines() : SummaryLines();
        results.ItemsSource = lines;
        hint.Visibility = lines.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    List<Line> SummaryLines()
    {
        List<Line> lines = [.. pass.Summary.Select(r => new Line(r.Name, $"{r.Items:N0} items", r.Bytes > 0 ? Bytes.Fmt(r.Bytes) : ""))];
        if (pass.Wipe) lines.Add(new Line("Wipe Free Space", "free space", ""));
        return lines;
    }

    List<Line> FileLines()
    {
        List<Line> lines = [.. pass.Files.Take(MaxFileLines).Select(f => new Line(f.FullName, "", Bytes.Fmt(f.Length), f.FullName))];
        if (pass.Files.Count > MaxFileLines) lines.Add(new Line($"... and {pass.Files.Count - MaxFileLines:N0} more files (see Summary for totals)", "", ""));
        lines.AddRange(pass.RegKeys.Take(MaxFileLines).Select(k => new Line(k.ToString(), "registry", "")));
        lines.AddRange(pass.Actions.Select(a => new Line(a.Label, "", a.Bytes > 0 ? Bytes.Fmt(a.Bytes) : "")));
        lines.AddRange(pass.BrowserRows.Select(r => new Line(r.Item.Key, $"{r.Count:N0} entries", "")));
        return lines;
    }

    // Writes the same Exclude list Options shows, and drops the file(s) from this run so Run Cleaner leaves them alone.
    void Exclude(bool folder)
    {
        if (results.SelectedItem is not Line { Path: { } file }) return;
        var dir = System.IO.Path.GetDirectoryName(file)!; // WPF drops System.IO from implicit usings (Shapes.Path)
        Custom.AddExclude(settings, folder ? $"PATH|{dir}" : $"FILE|{dir}|{System.IO.Path.GetFileName(file)}");
        pass.Files.RemoveAll(f => folder ? f.FullName.StartsWith(dir + "\\", StringComparison.OrdinalIgnoreCase)
                                         : f.FullName.Equals(file, StringComparison.OrdinalIgnoreCase));
        ShowResults();
        status.Text = $"Added to Exclude: {(folder ? dir : file)}. Analyze again to refresh the totals.";
        clean.IsEnabled = pass.Any;
    }

    // The trees stay enabled: Analyze/Clean took their ticks already, and disabling hundreds of checkboxes
    // floods screen readers (UI Automation) with one event per box.
    void SetBusy(bool busy, string text)
    {
        analyze.IsEnabled = !busy;
        clean.IsEnabled = false;
        status.Text = text;
        Cursor = busy ? Cursors.Wait : null;
    }

    public void SaveChecks()
    {
        foreach (var n in CheckNode.Items(windowGroups.Concat(appGroups)))
            if (n.Tag is Rule r && !CleanPass.IsWipe(r)) // wipe always starts off
                settings.Set(r.Name, n.IsChecked == true);
        foreach (var n in CheckNode.Items(browserGroups)) settings.Set(((BrowserItem)n.Tag!).Key, n.IsChecked == true);
        settings.Save();
    }
}
