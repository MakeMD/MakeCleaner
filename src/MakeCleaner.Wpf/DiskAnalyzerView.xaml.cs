using System.IO;
using System.Windows.Controls;

namespace MakeCleaner;

// Tools > Disk Analyzer: space by file type over the chosen locations; the category list doubles as the bar chart.
public partial class DiskAnalyzerView : UserControl
{
    const double BarMax = 200; // px of the longest bar
    DiskReport? report;

    public DiskAnalyzerView()
    {
        InitializeComponent();
        roots.Text = string.Join("; ", DriveInfo.GetDrives().Where(d => d.DriveType == DriveType.Fixed && d.IsReady).Select(d => d.RootDirectory.FullName));
        browse.Click += (_, _) => ToolsUi.PickFolder(roots);
        analyze.Click += async (_, _) =>
        {
            var where = Scan.SplitPaths(roots.Text); // read the box here: WPF controls belong to the UI thread
            await ToolsUi.Run(analyze, status, (ct, p) => DiskAnalyzer.Analyze(where, ct, p), Show);
        };
        cats.SelectionChanged += (_, _) => ShowFiles();
        files.MouseDoubleClick += (_, _) => OpenSelected();
        open.Click += (_, _) => OpenSelected();
        delete.Click += (_, _) => Delete();
        save.Click += (_, _) => { if (report != null) ToolsUi.SaveText(this, "DiskAnalyzer.txt", () => DiskAnalyzer.ToText(report)); };
    }

    void Show(DiskReport r)
    {
        report = r;
        var top = DiskAnalyzer.Categories.Max(r.Bytes);
        cats.ItemsSource = DiskAnalyzer.Categories.Select(c => new
        {
            Name = c,
            Size = Bytes.Fmt(r.Bytes(c)),
            Detail = $"{r.ByCategory[c].Count:N0} files" + (r.Total == 0 ? "" : $"  ·  {100.0 * r.Bytes(c) / r.Total:0.#}%"),
            Bar = top == 0 ? 0 : BarMax * r.Bytes(c) / top,
        }).ToList();
        status.Text = $"Analysis complete: {r.ByCategory.Values.Sum(l => l.Count):N0} files, {Bytes.Fmt(r.Total)}";
        cats.SelectedIndex = 0;
    }

    void ShowFiles()
    {
        if (report == null || cats.SelectedIndex < 0) { files.ItemsSource = null; return; }
        // ponytail: biggest 5000 per type; paging if the full list is ever needed
        files.ItemsSource = report.ByCategory[DiskAnalyzer.Categories[cats.SelectedIndex]].OrderByDescending(f => f.Length).Take(5000)
            .Select(f => new FileRow(f)).ToList();
    }

    void OpenSelected() { if (files.SelectedItem is FileRow r) ToolsUi.OpenFolder(r.File.FullName); }

    void Delete()
    {
        var picked = files.SelectedItems.Cast<FileRow>().Select(r => r.File).ToList();
        if (report == null || picked.Count == 0 || !ToolsUi.ConfirmDelete(this, picked.Count)) return;
        var r = Engine.Clean(picked);
        var gone = picked.Where(f => !f.Exists).ToHashSet();
        foreach (var l in report.ByCategory.Values) l.RemoveAll(gone.Contains);
        var cat = cats.SelectedIndex;
        Show(report);
        cats.SelectedIndex = cat;
        status.Text = $"Deleted {r.Deleted} files, {Bytes.Fmt(r.BytesFreed)} freed, {r.Skipped} skipped";
    }

    public record FileRow(FileInfo File)
    {
        public string Name => File.Name;
        public string Size => Bytes.Fmt(File.Length);
        public string Folder => File.DirectoryName ?? "";
        public string Modified => File.LastWriteTime.ToString("g");
    }
}
