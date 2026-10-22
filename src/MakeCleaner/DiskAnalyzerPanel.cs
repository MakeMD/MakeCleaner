namespace MakeCleaner;

public class DiskAnalyzerPanel : UserControl
{
    readonly TextBox roots;
    readonly ListView cats = new() { Dock = DockStyle.Left, Width = 330, View = View.Details, FullRowSelect = true, HideSelection = false, Name = "daCats" };
    readonly ListView files = new() { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, Name = "daFiles" };
    readonly Label status = new() { Dock = DockStyle.Bottom, Height = 24, TextAlign = ContentAlignment.MiddleLeft, Name = "daStatus" };
    readonly Button analyze = new() { Text = "Analyze", Width = 110, Name = "daScan" };
    DiskReport? report;

    public DiskAnalyzerPanel()
    {
        var fixedDrives = DriveInfo.GetDrives().Where(d => d.DriveType == DriveType.Fixed && d.IsReady).Select(d => d.RootDirectory.FullName);
        (roots, var rootsRow) = ToolsUi.PathRow("Locations", "daRoots", string.Join("; ", fixedDrives));

        cats.Columns.Add("Type", 110);
        cats.Columns.Add("Files", 70, HorizontalAlignment.Right);
        cats.Columns.Add("Size", 90, HorizontalAlignment.Right);
        cats.Columns.Add("%", 50, HorizontalAlignment.Right);
        files.Columns.Add("Name", 220);
        files.Columns.Add("Size", 90, HorizontalAlignment.Right);
        files.Columns.Add("Folder", 360);
        files.Columns.Add("Modified", 140);
        cats.SelectedIndexChanged += (_, _) => ShowFiles();
        files.ItemActivate += (_, _) => { if (files.FocusedItem?.Tag is FileInfo f) ToolsUi.OpenFolder(f.FullName); };

        var open = new Button { Text = "Open Folder", Width = 100 };
        var delete = new Button { Text = "Delete Selected", Width = 120 };
        var save = new Button { Text = "Save Report...", Width = 110 };
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 36, FlowDirection = FlowDirection.RightToLeft };
        buttons.Controls.AddRange([save, delete, open, analyze]);
        Controls.AddRange([files, cats, rootsRow, buttons, status]);

        analyze.Click += async (_, _) => await ToolsUi.Run(analyze, status, "Analyze", (ct, p) => DiskAnalyzer.Analyze(Scan.SplitPaths(roots.Text), ct, p), Show);
        open.Click += (_, _) => { if (files.SelectedItems.Count > 0) ToolsUi.OpenFolder(((FileInfo)files.SelectedItems[0].Tag!).FullName); };
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
        if (report == null || items.Count == 0 || !ToolsUi.ConfirmDelete(this, items.Count)) return;
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
