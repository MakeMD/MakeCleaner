namespace MakeCleaner;

public class MainForm : Form
{
    readonly Settings settings;
    readonly List<Rule> rules = Rule.ParseIni(Engine.BuiltInRules);
    readonly CheckedListBox items = new() { Dock = DockStyle.Left, Width = 220, CheckOnClick = true };
    readonly ListView results = new() { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true };
    readonly Label status = new() { Dock = DockStyle.Bottom, Height = 28, TextAlign = ContentAlignment.MiddleLeft, Name = "status" };
    readonly Button analyze = new() { Text = "Analyze", Width = 110, Name = "analyze" };
    readonly Button clean = new() { Text = "Run Cleaner", Width = 110, Enabled = false, Name = "clean" };
    List<FileInfo> found = [];

    public MainForm(Settings settings)
    {
        this.settings = settings;
        Text = "MakeCleaner";
        ClientSize = new Size(900, 560);
        StartPosition = FormStartPosition.CenterScreen;

        foreach (var r in rules) items.Items.Add(r.Name, settings.GetBool(r.Name, true));
        items.Items.Add(WipeItem, false); // ponytail: never persisted, always starts off
        items.ItemCheck += (_, e) =>
        {
            if (e.Index == rules.Count && e.NewValue == CheckState.Checked && MessageBox.Show(this,
                    "Wipe Free Space overwrites all free space on the system drive. It is slow, temporarily fills the drive " +
                    "and wears SSDs. Continue?", "MakeCleaner", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK)
                e.NewValue = CheckState.Unchecked;
        };
        results.Columns.Add("File", 600);
        results.Columns.Add("Size", 120, HorizontalAlignment.Right);
        results.Resize += (_, _) => results.Columns[0].Width = results.ClientSize.Width - results.Columns[1].Width;

        var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 40, FlowDirection = FlowDirection.RightToLeft };
        buttons.Controls.AddRange([clean, analyze]);
        var cleaner = new TabPage("Cleaner");
        cleaner.Controls.AddRange([results, items, buttons]);
        var tabs = new TabControl { Dock = DockStyle.Fill, Name = "tabs" };
        tabs.TabPages.Add(cleaner);
        tabs.TabPages.Add(ToolsPanel.Page("Tools", new ToolsPanel()));
        tabs.TabPages.Add(ToolsPanel.Page("Options", new OptionsPanel(settings)));
        Controls.AddRange([tabs, status]);

        analyze.Click += async (_, _) => await RunAnalyze();
        clean.Click += async (_, _) => await RunClean();
        FormClosing += (_, _) => SaveChecks();
    }

    const string WipeItem = "Wipe Free Space";
    List<Rule> Checked() => [.. rules.Where((_, i) => items.GetItemChecked(i))];
    bool WipeChecked => items.GetItemChecked(rules.Count);

    async Task RunAnalyze()
    {
        SetBusy(true, "Analyzing...");
        var selected = Checked();
        found = await Task.Run(() => selected.SelectMany(Engine.Analyze).ToList());
        results.BeginUpdate();
        results.Items.Clear();
        // ponytail: ListView capped at 5000 rows; virtual mode if lists get huge
        foreach (var f in found.Take(5000))
            results.Items.Add(new ListViewItem([f.FullName, Fmt(f.Length)]));
        results.EndUpdate();
        SetBusy(false, $"Analysis complete: {found.Count} files, {Fmt(found.Sum(f => f.Length))} to be removed"
            + (WipeChecked ? " + free space wipe" : ""));
        clean.Enabled = found.Count > 0 || WipeChecked;
    }

    async Task RunClean()
    {
        SetBusy(true, "Cleaning...");
        var toDelete = found;
        var passes = settings.GetInt(OptionsPanel.SecureDeleteKey, 0);
        var r = await Task.Run(() => Engine.Clean(toDelete, passes));
        found = [];
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
        SetBusy(false, $"Cleaning complete: {r.Deleted} files removed, {Fmt(r.BytesFreed)} freed, {r.Skipped} skipped (in use){wiped}");
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
