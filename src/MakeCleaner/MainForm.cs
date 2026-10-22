namespace MakeCleaner;

public class MainForm : Form
{
    readonly Settings settings;
    readonly List<Rule> rules = Rule.ParseIni(Engine.BuiltInRules);
    readonly TreeView windows = new() { Dock = DockStyle.Fill, CheckBoxes = true, Name = "windows" };
    readonly TreeView apps = new() { Dock = DockStyle.Fill, CheckBoxes = true, Name = "apps" };
    readonly TabControl cleanTabs = new() { Dock = DockStyle.Left, Width = 300 };
    readonly ListView results = new() { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true };
    readonly Label status = new() { Dock = DockStyle.Bottom, Height = 28, TextAlign = ContentAlignment.MiddleLeft, Name = "status" };
    readonly Button analyze = new() { Text = "Analyze", Width = 110, Name = "analyze" };
    readonly Button clean = new() { Text = "Run Cleaner", Width = 110, Enabled = false, Name = "clean" };
    readonly LinkLabel about = new() { Text = "About", AutoSize = true, Padding = new Padding(0, 8, 0, 0) };
    List<Rule> scanned = [];
    List<FileInfo> found = [];
    List<RegKey> foundReg = [];
    List<Pending> foundActions = [];

    public MainForm(Settings settings)
    {
        this.settings = settings;
        Text = "MakeCleaner";
        ClientSize = new Size(1000, 600);
        StartPosition = FormStartPosition.CenterScreen;

        Fill(windows, rules.Where(r => r.IsDetected()));
        windows.ExpandAll();
        var winPage = new TabPage("Windows");
        winPage.Controls.Add(windows);
        var appPage = new TabPage("Applications");
        appPage.Controls.Add(apps);
        cleanTabs.TabPages.AddRange([winPage, appPage]);
        results.Columns.Add("File / registry", 700);
        results.Columns.Add("Size", 120, HorizontalAlignment.Right);
        results.Resize += (_, _) => results.Columns[0].Width = results.ClientSize.Width - results.Columns[1].Width;

        var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 40, FlowDirection = FlowDirection.RightToLeft };
        buttons.Controls.AddRange([clean, analyze, about]);
        var cleaner = new TabPage("Cleaner");
        cleaner.Controls.AddRange([results, cleanTabs, buttons]);
        var tabs = new TabControl { Dock = DockStyle.Fill, Name = "tabs" };
        tabs.TabPages.Add(cleaner);
        tabs.TabPages.Add(ToolsPanel.Page("Registry", new RegistryPanel(settings)));
        tabs.TabPages.Add(ToolsPanel.Page("Tools", new ToolsPanel()));
        tabs.TabPages.Add(ToolsPanel.Page("Options", new OptionsPanel(settings)));
        Controls.AddRange([tabs, status]);

        analyze.Click += async (_, _) => await RunAnalyze();
        clean.Click += async (_, _) => await RunClean();
        about.LinkClicked += (_, _) => MessageBox.Show(this,
            "MakeCleaner - no telemetry, no ads, no network access.\n\n" +
            "Applications rules: Winapp2.ini by the Winapp2 project (github.com/MoscaDotTo/Winapp2), " +
            "licensed CC BY-SA 4.0, shipped unmodified in rules\\Winapp2.ini.", "About MakeCleaner");
        foreach (var tree in new[] { windows, apps })
        {
            tree.BeforeCheck += ConfirmWarning;
            tree.AfterCheck += (_, e) =>
            {
                if (e.Action == TreeViewAction.Unknown) return; // programmatic: no cascade loops
                foreach (TreeNode child in e.Node!.Nodes) child.Checked = e.Node.Checked;
            };
        }
        Load += async (_, _) => await LoadApps();
        FormClosing += (_, _) => SaveChecks();
    }

    async Task LoadApps()
    {
        status.Text = "Detecting installed applications...";
        var list = await Task.Run(() => Rule.LoadApplications(AppContext.BaseDirectory));
        Fill(apps, list);
        status.Text = $"{list.Count} applications detected";
    }

    // One group node per Rule.Group (in rule order), one checkbox per rule.
    void Fill(TreeView tree, IEnumerable<Rule> list)
    {
        tree.BeginUpdate();
        foreach (var g in list.GroupBy(r => r.Group))
        {
            var group = tree.Nodes.Add(g.Key);
            foreach (var r in g)
                group.Nodes.Add(new TreeNode(r.Name) { Tag = r, Checked = settings.GetBool(r.Name, r.Default) });
            group.Checked = group.Nodes.Cast<TreeNode>().All(n => n.Checked);
        }
        tree.EndUpdate();
    }

    // Entries with Warning= need an explicit yes before they get ticked.
    void ConfirmWarning(object? sender, TreeViewCancelEventArgs e)
    {
        if (e.Node!.Checked || e.Node.Tag is not Rule { Warning: { } w } r) return;
        e.Cancel = MessageBox.Show(this, w, r.Name, MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK;
    }

    IEnumerable<TreeNode> Leaves() =>
        new[] { windows, apps }.SelectMany(t => t.Nodes.Cast<TreeNode>()).SelectMany(g => g.Nodes.Cast<TreeNode>());

    List<Rule> Checked() => [.. Leaves().Where(n => n.Checked).Select(n => (Rule)n.Tag!)];

    bool WipeChecked => scanned.Any(r => r.SpecialKeys.Contains(Special.WipeFreeSpace, StringComparer.OrdinalIgnoreCase));

    async Task RunAnalyze()
    {
        SetBusy(true, "Analyzing...");
        scanned = Checked();
        foreach (var r in scanned) r.OlderThanHours = r.AgeOption != null && settings.GetBool(r.AgeOption, false) ? 24 : null;
        var selected = scanned;
        (found, foundReg, foundActions) = await Task.Run(() => (selected.SelectMany(Engine.Analyze).DistinctBy(f => f.FullName).ToList(),
                                                                selected.SelectMany(Engine.AnalyzeRegistry).Distinct().ToList(),
                                                                selected.SelectMany(Engine.AnalyzeActions).ToList()));
        results.BeginUpdate();
        results.Items.Clear();
        // ponytail: ListView capped at 5000 rows; virtual mode if lists get huge
        foreach (var f in found.Take(5000))
            results.Items.Add(new ListViewItem([f.FullName, Fmt(f.Length)]));
        foreach (var t in foundReg.Take(5000))
            results.Items.Add(new ListViewItem([t.ToString(), ""]));
        foreach (var a in foundActions)
            results.Items.Add(new ListViewItem([a.Label, a.Bytes > 0 ? Fmt(a.Bytes) : ""]));
        results.EndUpdate();
        SetBusy(false, $"Analysis complete: {found.Count} files, {Fmt(found.Sum(f => f.Length))} to be removed, {foundReg.Count} registry entries"
            + (foundActions.Count > 0 ? $", {foundActions.Count} other items" : "") + (WipeChecked ? " + free space wipe" : ""));
        clean.Enabled = found.Count + foundReg.Count + foundActions.Count > 0 || WipeChecked;
    }

    async Task RunClean()
    {
        SetBusy(true, "Cleaning...");
        var (toDelete, toDeleteReg, toRun, ruleSet) = (found, foundReg, foundActions, scanned);
        var passes = settings.GetInt(OptionsPanel.SecureDeleteKey, 0);
        var (r, rr, ra) = await Task.Run(() =>
        {
            var fr = Engine.Clean(toDelete, passes);
            var reg = Engine.CleanRegistry(toDeleteReg);
            var act = Engine.RunActions(toRun);
            foreach (var rule in ruleSet) Engine.RemoveEmptyDirs(rule);
            return (fr, reg, act);
        });
        found = [];
        foundReg = [];
        foundActions = [];
        results.Items.Clear();
        var wiped = "";
        if (WipeChecked)
        {
            // %TEMP% lives on the system drive and is writable without admin; other drives: Tools > Drive Wiper
            var progress = new Progress<string>(s => status.Text = "Wiping free space... " + s);
            try
            {
                await Task.Run(() => SecureDelete.WipeFreeSpace(Path.GetTempPath(), Math.Max(1, passes), progress));
                wiped = ", free space wiped";
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { wiped = ", free space wipe failed: " + e.Message; }
        }
        SetBusy(false, $"Cleaning complete: {r.Deleted} files removed, {Fmt(r.BytesFreed)} freed, {r.Skipped} skipped (in use), {rr.Deleted} registry entries removed, {rr.Skipped} skipped"
            + (ra.Deleted + ra.Skipped > 0 ? $", {ra.Deleted} other items done" + (ra.Skipped > 0 ? $" ({ra.Skipped} failed)" : "") : "") + wiped);
        clean.Enabled = false;
    }

    void SetBusy(bool busy, string text)
    {
        analyze.Enabled = !busy;
        clean.Enabled = false;
        status.Text = text;
        UseWaitCursor = busy;
    }

    void SaveChecks()
    {
        foreach (var n in Leaves())
            if (n.Tag is Rule r && !r.SpecialKeys.Contains(Special.WipeFreeSpace, StringComparer.OrdinalIgnoreCase)) // wipe always starts off
                settings.Set(r.Name, n.Checked);
        settings.Save();
    }

    internal static string Fmt(long b) => b switch
    {
        >= 1L << 30 => $"{b / (double)(1L << 30):0.##} GB",
        >= 1L << 20 => $"{b / (double)(1L << 20):0.##} MB",
        >= 1L << 10 => $"{b / 1024.0:0.##} KB",
        _ => $"{b} B",
    };
}
