using System.Diagnostics;

namespace MakeCleaner;

// Tools section: one nested tab per tool. New tools = one more page in the AddRange below.
public class ToolsPage : TabPage
{
    public ToolsPage() : base("Tools")
    {
        var tabs = new TabControl { Dock = DockStyle.Fill, Name = "toolTabs" };
        tabs.TabPages.AddRange([new DuplicatesPage(), new DiskAnalyzerPage()]);
        Controls.Add(tabs);
    }

    // Scan button doubles as Cancel; work runs off the UI thread, progress = files seen.
    public static async Task Run<T>(Button btn, Label status, string idle, Func<CancellationToken, IProgress<int>, T> work, Action<T> done)
    {
        if (btn.Tag is CancellationTokenSource running) { running.Cancel(); return; }
        using var cts = new CancellationTokenSource();
        btn.Tag = cts;
        btn.Text = "Cancel";
        var progress = new Progress<int>(n => status.Text = $"Scanning... {n:N0} files");
        status.Text = "Scanning...";
        try { done(await Task.Run(() => work(cts.Token, progress))); }
        catch (OperationCanceledException) { status.Text = "Cancelled"; }
        finally { btn.Tag = null; btn.Text = idle; }
    }

    public static (TextBox, Panel) PathRow(string label, string name, string text)
    {
        var box = new TextBox { Dock = DockStyle.Fill, Name = name, Text = text };
        var browse = new Button { Text = "...", Dock = DockStyle.Right, Width = 32 };
        browse.Click += (_, _) =>
        {
            using var d = new FolderBrowserDialog();
            if (d.ShowDialog() == DialogResult.OK) box.Text = box.Text.Length == 0 ? d.SelectedPath : $"{box.Text}; {d.SelectedPath}";
        };
        var row = new Panel { Dock = DockStyle.Top, Height = 28, Padding = new Padding(4, 3, 4, 2) };
        row.Controls.AddRange([box, browse, new Label { Text = label, Dock = DockStyle.Left, Width = 70, TextAlign = ContentAlignment.MiddleLeft }]);
        return (box, row);
    }

    public static bool ConfirmDelete(IWin32Window owner, int count) =>
        MessageBox.Show(owner, $"Delete {count} file(s)? This cannot be undone.", "MakeCleaner",
            MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) == DialogResult.Yes;

    public static void OpenFolder(string file) => Process.Start("explorer.exe", $"/select,\"{file}\"");
}

public class DuplicatesPage : TabPage
{
    readonly CheckBox byName = new() { Text = "Name", Checked = true, AutoSize = true };
    readonly CheckBox bySize = new() { Text = "Size", Checked = true, AutoSize = true };
    readonly CheckBox byDate = new() { Text = "Modified date", Checked = true, AutoSize = true };
    readonly CheckBox byContent = new() { Text = "Content", AutoSize = true };
    readonly CheckBox noEmpty = new() { Text = "Zero-byte", Checked = true, AutoSize = true };
    readonly CheckBox noSystem = new() { Text = "System", Checked = true, AutoSize = true };
    readonly CheckBox noHidden = new() { Text = "Hidden", Checked = true, AutoSize = true };
    readonly CheckBox noReadOnly = new() { Text = "Read-only", AutoSize = true };
    readonly NumericUpDown minMb = new() { Maximum = 1_000_000, Width = 70 };
    readonly NumericUpDown maxMb = new() { Maximum = 1_000_000, Width = 70 };
    readonly TextBox include, exclude;
    readonly ListView list = new() { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, CheckBoxes = true, Name = "dupList" };
    readonly Label status = new() { Dock = DockStyle.Bottom, Height = 24, TextAlign = ContentAlignment.MiddleLeft, Name = "dupStatus" };
    readonly Button search = new() { Text = "Search", Width = 110, Name = "dupSearch" };

    public DuplicatesPage() : base("Duplicate Finder")
    {
        var match = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(4) };
        match.Controls.AddRange([new Label { Text = "Match by:", AutoSize = true, Padding = new Padding(0, 4, 0, 0) }, byName, bySize, byDate, byContent,
            new Label { Text = "Ignore:", AutoSize = true, Padding = new Padding(12, 4, 0, 0) }, noEmpty, noSystem, noHidden, noReadOnly,
            new Label { Text = "Size MB from", AutoSize = true, Padding = new Padding(12, 4, 0, 0) }, minMb,
            new Label { Text = "to (0 = any)", AutoSize = true, Padding = new Padding(0, 4, 0, 0) }, maxMb]);
        (include, var incRow) = ToolsPage.PathRow("Include", "dupInclude", Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        (exclude, var excRow) = ToolsPage.PathRow("Exclude", "dupExclude", Environment.GetFolderPath(Environment.SpecialFolder.Windows));

        list.Columns.Add("Name", 220);
        list.Columns.Add("Folder", 380);
        list.Columns.Add("Size", 90, HorizontalAlignment.Right);
        list.Columns.Add("Modified", 140);
        list.ItemActivate += (_, _) => { if (list.FocusedItem?.Tag is FileInfo f) ToolsPage.OpenFolder(f.FullName); };

        var selectDupes = new Button { Text = "Select all but first", Width = 140 };
        var delete = new Button { Text = "Delete Selected", Width = 120, Name = "dupDelete" };
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 36, FlowDirection = FlowDirection.RightToLeft };
        buttons.Controls.AddRange([delete, selectDupes, search]);
        Controls.AddRange([list, excRow, incRow, match, buttons, status]);

        search.Click += async (_, _) => await ToolsPage.Run(search, status, "Search", (ct, p) => Duplicates.Find(Options(), ct, p), Show);
        selectDupes.Click += (_, _) =>
        {
            foreach (ListViewGroup g in list.Groups)
                for (int i = 0; i < g.Items.Count; i++) g.Items[i].Checked = i > 0;
        };
        delete.Click += (_, _) => Delete();
    }

    DupOptions Options() => new()
    {
        Include = Scan.SplitPaths(include.Text),
        Exclude = Scan.SplitPaths(exclude.Text),
        ByName = byName.Checked, BySize = bySize.Checked, ByDate = byDate.Checked, ByContent = byContent.Checked,
        IgnoreEmpty = noEmpty.Checked, IgnoreSystem = noSystem.Checked, IgnoreHidden = noHidden.Checked, IgnoreReadOnly = noReadOnly.Checked,
        MinSize = (long)minMb.Value << 20,
        MaxSize = maxMb.Value == 0 ? long.MaxValue : (long)maxMb.Value << 20,
    };

    void Show(DupResult r)
    {
        list.BeginUpdate();
        list.Items.Clear();
        list.Groups.Clear();
        // ponytail: capped at 2000 groups; virtual mode if someone has more
        foreach (var (g, i) in r.Groups.OrderByDescending(g => g[0].Length * (g.Count - 1)).Take(2000).Select((g, i) => (g, i)))
        {
            var group = new ListViewGroup($"#{i + 1}: {g.Count} x {MainForm.Fmt(g[0].Length)}");
            list.Groups.Add(group);
            foreach (var f in g)
                list.Items.Add(new ListViewItem([f.Name, f.DirectoryName ?? "", MainForm.Fmt(f.Length), f.LastWriteTime.ToString("g")], group) { Tag = f });
        }
        list.EndUpdate();
        var wasted = r.Groups.Sum(g => g[0].Length * (g.Count - 1));
        status.Text = $"Found {r.Groups.Count} duplicate groups, {r.Groups.Sum(g => g.Count)} files, {MainForm.Fmt(wasted)} reclaimable";
    }

    void Delete()
    {
        var items = list.CheckedItems.Cast<ListViewItem>().ToList();
        if (items.Count == 0 || !ToolsPage.ConfirmDelete(this, items.Count)) return;
        var r = Engine.Clean(items.Select(i => (FileInfo)i.Tag!));
        foreach (var i in items.Where(i => !((FileInfo)i.Tag!).Exists)) list.Items.Remove(i);
        status.Text = $"Deleted {r.Deleted} files, {MainForm.Fmt(r.BytesFreed)} freed, {r.Skipped} skipped";
    }
}

public class DiskAnalyzerPage : TabPage
{
    readonly TextBox roots;
    readonly ListView cats = new() { Dock = DockStyle.Left, Width = 330, View = View.Details, FullRowSelect = true, HideSelection = false, Name = "daCats" };
    readonly ListView files = new() { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, Name = "daFiles" };
    readonly Label status = new() { Dock = DockStyle.Bottom, Height = 24, TextAlign = ContentAlignment.MiddleLeft, Name = "daStatus" };
    readonly Button analyze = new() { Text = "Analyze", Width = 110, Name = "daScan" };
    DiskReport? report;

    public DiskAnalyzerPage() : base("Disk Analyzer")
    {
        var fixedDrives = DriveInfo.GetDrives().Where(d => d.DriveType == DriveType.Fixed && d.IsReady).Select(d => d.RootDirectory.FullName);
        (roots, var rootsRow) = ToolsPage.PathRow("Locations", "daRoots", string.Join("; ", fixedDrives));

        cats.Columns.Add("Type", 110);
        cats.Columns.Add("Files", 70, HorizontalAlignment.Right);
        cats.Columns.Add("Size", 90, HorizontalAlignment.Right);
        cats.Columns.Add("%", 50, HorizontalAlignment.Right);
        files.Columns.Add("Name", 220);
        files.Columns.Add("Size", 90, HorizontalAlignment.Right);
        files.Columns.Add("Folder", 360);
        files.Columns.Add("Modified", 140);
        cats.SelectedIndexChanged += (_, _) => ShowFiles();
        files.ItemActivate += (_, _) => { if (files.FocusedItem?.Tag is FileInfo f) ToolsPage.OpenFolder(f.FullName); };

        var open = new Button { Text = "Open Folder", Width = 100 };
        var delete = new Button { Text = "Delete Selected", Width = 120 };
        var save = new Button { Text = "Save Report...", Width = 110 };
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 36, FlowDirection = FlowDirection.RightToLeft };
        buttons.Controls.AddRange([save, delete, open, analyze]);
        Controls.AddRange([files, cats, rootsRow, buttons, status]);

        analyze.Click += async (_, _) => await ToolsPage.Run(analyze, status, "Analyze", (ct, p) => DiskAnalyzer.Analyze(Scan.SplitPaths(roots.Text), ct, p), Show);
        open.Click += (_, _) => { if (files.SelectedItems.Count > 0) ToolsPage.OpenFolder(((FileInfo)files.SelectedItems[0].Tag!).FullName); };
        delete.Click += (_, _) => Delete();
        save.Click += (_, _) => Save();
    }

    void Show(DiskReport r)
    {
        report = r;
        cats.BeginUpdate();
        cats.Items.Clear();
        foreach (var c in DiskAnalyzer.Categories)
            cats.Items.Add(new ListViewItem([c, r.ByCategory[c].Count.ToString("N0"), MainForm.Fmt(r.Bytes(c)),
                r.Total == 0 ? "0" : $"{100.0 * r.Bytes(c) / r.Total:0.#}"]) { Tag = c });
        cats.EndUpdate();
        status.Text = $"Analysis complete: {r.ByCategory.Values.Sum(l => l.Count):N0} files, {MainForm.Fmt(r.Total)}";
        if (cats.Items.Count > 0) cats.Items[0].Selected = true;
    }

    void ShowFiles()
    {
        files.BeginUpdate();
        files.Items.Clear();
        if (report != null && cats.SelectedItems.Count > 0)
            // ponytail: biggest 5000 per type; virtual mode if the full list is ever needed
            foreach (var f in report.ByCategory[(string)cats.SelectedItems[0].Tag!].OrderByDescending(f => f.Length).Take(5000))
                files.Items.Add(new ListViewItem([f.Name, MainForm.Fmt(f.Length), f.DirectoryName ?? "", f.LastWriteTime.ToString("g")]) { Tag = f });
        files.EndUpdate();
    }

    void Delete()
    {
        var items = files.SelectedItems.Cast<ListViewItem>().ToList();
        if (report == null || items.Count == 0 || !ToolsPage.ConfirmDelete(this, items.Count)) return;
        var picked = items.Select(i => (FileInfo)i.Tag!).ToList();
        var r = Engine.Clean(picked);
        var gone = picked.Where(f => !f.Exists).ToHashSet();
        foreach (var l in report.ByCategory.Values) l.RemoveAll(gone.Contains);
        var cat = cats.SelectedIndices.Count > 0 ? cats.SelectedIndices[0] : 0;
        Show(report);
        cats.Items[cat].Selected = true;
        status.Text = $"Deleted {r.Deleted} files, {MainForm.Fmt(r.BytesFreed)} freed, {r.Skipped} skipped";
    }

    void Save()
    {
        if (report == null) return;
        using var d = new SaveFileDialog { Filter = "Text files (*.txt)|*.txt", FileName = "DiskAnalyzer.txt" };
        if (d.ShowDialog(this) == DialogResult.OK) File.WriteAllText(d.FileName, DiskAnalyzer.ToText(report));
    }
}
