namespace MakeCleaner;

public class MainForm : Form
{
    readonly Settings settings;
    readonly List<Rule> rules = Rule.ParseIni(Engine.BuiltInRules);
    readonly CheckedListBox items = new() { Dock = DockStyle.Fill, CheckOnClick = true };
    readonly TreeView apps = new() { Dock = DockStyle.Fill, CheckBoxes = true, Name = "apps" };
    readonly TabControl tabs = new() { Dock = DockStyle.Left, Width = 300 };
    readonly ListView results = new() { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true };
    readonly Label status = new() { Dock = DockStyle.Bottom, Height = 28, TextAlign = ContentAlignment.MiddleLeft, Name = "status" };
    readonly Button analyze = new() { Text = "Analyze", Width = 110, Name = "analyze" };
    readonly Button clean = new() { Text = "Run Cleaner", Width = 110, Enabled = false, Name = "clean" };
    readonly LinkLabel about = new() { Text = "About", AutoSize = true, Padding = new Padding(0, 8, 0, 0) };
    List<Rule> scanned = [];
    List<FileInfo> found = [];
    List<RegKey> foundReg = [];

    public MainForm(Settings settings)
    {
        this.settings = settings;
        Text = "MakeCleaner";
        ClientSize = new Size(1000, 600);
        StartPosition = FormStartPosition.CenterScreen;

        foreach (var r in rules) items.Items.Add(r.Name, settings.GetBool(r.Name, r.Default));
        var winPage = new TabPage("Windows");
        winPage.Controls.Add(items);
        var appPage = new TabPage("Applications");
        appPage.Controls.Add(apps);
        tabs.TabPages.AddRange([winPage, appPage]);
        results.Columns.Add("File / registry", 700);
        results.Columns.Add("Size", 120, HorizontalAlignment.Right);
        results.Resize += (_, _) => results.Columns[0].Width = results.ClientSize.Width - results.Columns[1].Width;

        var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 40, FlowDirection = FlowDirection.RightToLeft };
        buttons.Controls.AddRange([clean, analyze, about]);
        Controls.AddRange([results, tabs, buttons, status]);

        analyze.Click += async (_, _) => await RunAnalyze();
        clean.Click += async (_, _) => await RunClean();
        about.LinkClicked += (_, _) => MessageBox.Show(this,
            "MakeCleaner - no telemetry, no ads, no network access.\n\n" +
            "Applications rules: Winapp2.ini by the Winapp2 project (github.com/MoscaDotTo/Winapp2), " +
            "licensed CC BY-SA 4.0, shipped unmodified in rules\\Winapp2.ini.", "About MakeCleaner");
        apps.BeforeCheck += ConfirmWarning;
        apps.AfterCheck += (_, e) =>
        {
            if (e.Action == TreeViewAction.Unknown) return; // programmatic: no cascade loops
            foreach (TreeNode child in e.Node!.Nodes) child.Checked = e.Node.Checked;
        };
        Load += async (_, _) => await LoadApps();
        FormClosing += (_, _) => SaveChecks();
    }

    async Task LoadApps()
    {
        status.Text = "Detecting installed applications...";
        var list = await Task.Run(() => Rule.LoadApplications(AppContext.BaseDirectory));
        apps.BeginUpdate();
        foreach (var g in list.GroupBy(r => r.Group))
        {
            var group = apps.Nodes.Add(g.Key);
            foreach (var r in g)
                group.Nodes.Add(new TreeNode(r.Name) { Tag = r, Checked = settings.GetBool(r.Name, r.Default) });
            group.Checked = group.Nodes.Cast<TreeNode>().All(n => n.Checked);
        }
        apps.EndUpdate();
        status.Text = $"{list.Count} applications detected";
    }

    // Entries with Warning= need an explicit yes before they get ticked.
    void ConfirmWarning(object? sender, TreeViewCancelEventArgs e)
    {
        if (e.Node!.Checked || e.Node.Tag is not Rule { Warning: { } w } r) return;
        e.Cancel = MessageBox.Show(this, w, r.Name, MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK;
    }

    IEnumerable<TreeNode> Leaves() => apps.Nodes.Cast<TreeNode>().SelectMany(g => g.Nodes.Cast<TreeNode>());

    List<Rule> Checked() =>
        [.. rules.Where((_, i) => items.GetItemChecked(i)), .. Leaves().Where(n => n.Checked).Select(n => (Rule)n.Tag!)];

    async Task RunAnalyze()
    {
        SetBusy(true, "Analyzing...");
        scanned = Checked();
        var selected = scanned;
        (found, foundReg) = await Task.Run(() => (selected.SelectMany(Engine.Analyze).DistinctBy(f => f.FullName).ToList(),
                                                  selected.SelectMany(Engine.AnalyzeRegistry).Distinct().ToList()));
        results.BeginUpdate();
        results.Items.Clear();
        // ponytail: ListView capped at 5000 rows; virtual mode if lists get huge
        foreach (var f in found.Take(5000))
            results.Items.Add(new ListViewItem([f.FullName, Fmt(f.Length)]));
        foreach (var t in foundReg.Take(5000))
            results.Items.Add(new ListViewItem([t.ToString(), ""]));
        results.EndUpdate();
        SetBusy(false, $"Analysis complete: {found.Count} files, {Fmt(found.Sum(f => f.Length))} to be removed, {foundReg.Count} registry entries");
        clean.Enabled = found.Count + foundReg.Count > 0;
    }

    async Task RunClean()
    {
        SetBusy(true, "Cleaning...");
        var (toDelete, toDeleteReg, ruleSet) = (found, foundReg, scanned);
        var (r, rr) = await Task.Run(() =>
        {
            var fr = Engine.Clean(toDelete);
            var reg = Engine.CleanRegistry(toDeleteReg);
            foreach (var rule in ruleSet) Engine.RemoveEmptyDirs(rule);
            return (fr, reg);
        });
        found = [];
        foundReg = [];
        results.Items.Clear();
        SetBusy(false, $"Cleaning complete: {r.Deleted} files removed, {Fmt(r.BytesFreed)} freed, {r.Skipped} skipped (in use), {rr.Deleted} registry entries removed, {rr.Skipped} skipped");
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
        for (int i = 0; i < rules.Count; i++) settings.Set(rules[i].Name, items.GetItemChecked(i));
        foreach (var n in Leaves()) settings.Set(((Rule)n.Tag!).Name, n.Checked);
        settings.Save();
    }

    static string Fmt(long b) => b switch
    {
        >= 1L << 30 => $"{b / (double)(1L << 30):0.##} GB",
        >= 1L << 20 => $"{b / (double)(1L << 20):0.##} MB",
        >= 1L << 10 => $"{b / 1024.0:0.##} KB",
        _ => $"{b} B",
    };
}
