using System.IO;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;

namespace MakeCleaner;

// Tools > Duplicate Finder: settings form -> grouped results (Back returns to the form).
public partial class DuplicatesView : UserControl
{
    public DuplicatesView()
    {
        InitializeComponent();
        include.Text = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        exclude.Text = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        browseInclude.Click += (_, _) => ToolsUi.PickFolder(include);
        browseExclude.Click += (_, _) => ToolsUi.PickFolder(exclude);
        search.Click += async (_, _) =>
        {
            var o = Options(); // read the form here: WPF controls belong to the UI thread
            await ToolsUi.Run(search, status, (ct, p) => Duplicates.Find(o, ct, p), Show);
        };
        back.Click += (_, _) => Page(results: false);
        list.MouseDoubleClick += (_, _) => { if (list.SelectedItem is DupRow r) ToolsUi.OpenFolder(r.File.FullName); };
        selectDupes.Click += (_, _) =>
        {
            foreach (var g in Rows().GroupBy(r => r.Group))
                foreach (var (r, i) in g.Select((r, i) => (r, i))) r.IsChecked = i > 0;
        };
        delete.Click += (_, _) => Delete();
    }

    void Page(bool results)
    {
        setup.Visibility = results ? Visibility.Collapsed : Visibility.Visible;
        this.results.Visibility = results ? Visibility.Visible : Visibility.Collapsed;
    }

    IEnumerable<DupRow> Rows() => list.ItemsSource is ListCollectionView v ? v.Cast<DupRow>() : [];

    static long Mb(TextBox box) => long.TryParse(box.Text.Trim(), out var v) && v > 0 ? v << 20 : 0;

    DupOptions Options() => new()
    {
        Include = Scan.SplitPaths(include.Text),
        Exclude = Scan.SplitPaths(exclude.Text),
        ByName = byName.IsChecked == true, BySize = bySize.IsChecked == true, ByDate = byDate.IsChecked == true, ByContent = byContent.IsChecked == true,
        IgnoreEmpty = noEmpty.IsChecked == true, IgnoreSystem = noSystem.IsChecked == true,
        IgnoreHidden = noHidden.IsChecked == true, IgnoreReadOnly = noReadOnly.IsChecked == true,
        MinSize = Mb(minMb),
        MaxSize = Mb(maxMb) is var max and > 0 ? max : long.MaxValue,
    };

    void Show(DupResult r)
    {
        // ponytail: capped at 2000 groups, biggest waste first; paging if someone has more
        var rows = r.Groups.OrderByDescending(g => g[0].Length * (g.Count - 1)).Take(2000)
            .SelectMany((g, i) => g.Select(f => new DupRow(f, $"#{i + 1}: {g.Count} x {Bytes.Fmt(g[0].Length)}")))
            .ToList();
        var view = new ListCollectionView(rows);
        view.GroupDescriptions.Add(new PropertyGroupDescription(nameof(DupRow.Group)));
        list.ItemsSource = view;
        var wasted = r.Groups.Sum(g => g[0].Length * (g.Count - 1));
        status.Text = $"Found {r.Groups.Count} duplicate groups, {r.Groups.Sum(g => g.Count)} files, {Bytes.Fmt(wasted)} reclaimable";
        Page(results: true);
    }

    void Delete()
    {
        var picked = Rows().Where(r => r.IsChecked).ToList();
        if (picked.Count == 0 || !ToolsUi.ConfirmDelete(this, picked.Count)) return;
        var r = Engine.Clean(picked.Select(p => p.File));
        var view = (ListCollectionView)list.ItemsSource;
        foreach (var p in picked.Where(p => !p.File.Exists)) view.Remove(p);
        status.Text = $"Deleted {r.Deleted} files, {Bytes.Fmt(r.BytesFreed)} freed, {r.Skipped} skipped";
    }
}

public sealed class DupRow(FileInfo file, string group) : INotifyPropertyChanged
{
    public FileInfo File { get; } = file;
    public string Group { get; } = group;
    public string Name => File.Name;
    public string Folder => File.DirectoryName ?? "";
    public string Size => Bytes.Fmt(File.Length);
    public string Modified => File.LastWriteTime.ToString("g");
    bool on;
    public bool IsChecked
    {
        get => on;
        set { if (on != value) { on = value; PropertyChanged?.Invoke(this, new(nameof(IsChecked))); } }
    }
    public event PropertyChangedEventHandler? PropertyChanged;
}
