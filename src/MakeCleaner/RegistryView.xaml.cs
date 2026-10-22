using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;

namespace MakeCleaner;

// Registry: category checklist -> Scan (progress, Cancel; read-only) -> tick issues -> Review:
// mandatory .reg backup of every ticked issue, then the n/N dialog that fixes them one by one or all at once.
public partial class RegistryView : UserControl
{
    // One issue line; the box is the user's pick for Review.
    public sealed class Row(RegIssue issue) : INotifyPropertyChanged
    {
        public RegIssue Issue { get; } = issue;
        bool on = true;
        public bool IsChecked { get => on; set { on = value; PropertyChanged?.Invoke(this, new(nameof(IsChecked))); } }
        public event PropertyChangedEventHandler? PropertyChanged;
    }

    readonly Settings settings;
    readonly CheckNode categories;
    List<Row> rows = [];
    CancellationTokenSource? cts;

    public RegistryView(Settings settings)
    {
        InitializeComponent();
        this.settings = settings;
        // CheckNode gives the "All categories" box its third state for free; same "Reg:" keys as the classic window.
        categories = CheckNode.Group("All categories",
            RegScanner.Categories.Select(c => new CheckNode(c.Name, c, null, settings.GetBool("Reg:" + c.Name, true))), expanded: true);
        foreach (var c in categories.Children)
            c.PropertyChanged += (_, _) => { settings.Set("Reg:" + c.Label, c.IsChecked == true); settings.Save(); };
        all.DataContext = categories;
        cats.ItemsSource = categories.Children;

        scan.Click += async (_, _) => await RunScan();
        cancel.Click += (_, _) => { cts?.Cancel(); status.Text = "Cancelling..."; };
        review.Click += (_, _) => RunReview();
        list.SizeChanged += (_, _) => // Data and Registry key share whatever the box and Problem leave
        {
            var cols = ((GridView)list.View).Columns;
            var rest = Math.Max(300, list.ActualWidth - cols[0].Width - cols[1].Width - 32);
            cols[2].Width = rest * 0.45;
            cols[3].Width = rest * 0.55;
        };
        list.ContextMenuOpening += (_, _) =>
            selectType.IsEnabled = selectTypeNone.IsEnabled = openRegedit.IsEnabled = exclude.IsEnabled = Selected() != null;
        selectAll.Click += (_, _) => Tick(_ => true, true);
        selectNone.Click += (_, _) => Tick(_ => true, false);
        selectType.Click += (_, _) => { if (Selected() is { } s) Tick(r => r.Issue.Category == s.Category, true); };
        selectTypeNone.Click += (_, _) => { if (Selected() is { } s) Tick(r => r.Issue.Category == s.Category, false); };
        openRegedit.Click += (_, _) => { if (Selected() is { } s) OpenInRegedit(s.KeyPath); };
        exclude.Click += (_, _) => { if (Selected() is { } s) Exclude(s); };
    }

    RegIssue? Selected() => (list.SelectedItem as Row)?.Issue;

    void Tick(Func<Row, bool> which, bool on) { foreach (var r in rows.Where(which)) r.IsChecked = on; }

    async Task RunScan()
    {
        var chosen = categories.Children.Where(c => c.IsChecked == true).Select(c => (RegCategory)c.Tag!).ToList();
        if (chosen.Count == 0) { status.Text = "Tick at least one category on the left."; return; }
        scan.IsEnabled = review.IsEnabled = false;
        cancel.IsEnabled = true;
        Cursor = Cursors.Wait;
        status.Text = "Scanning...";
        progress.Maximum = chosen.Count;
        cts = new CancellationTokenSource();
        var (token, excluded, found) = (cts.Token, Custom.RegistryExcludes(settings), new List<RegIssue>());
        try
        {
            var scanner = RegScanner.ForThisPc();
            for (int i = 0; i < chosen.Count; i++) // a category at a time, so the bar moves and Cancel lands quickly
            {
                progressText.Text = $"{i * 100 / chosen.Count}% ({i} of {chosen.Count})";
                status.Text = $"Scanning: {chosen[i].Name}...";
                var cat = chosen[i];
                found.AddRange(await Task.Run(() => scanner.Scan([cat], excluded, token)));
                progress.Value = i + 1;
            }
            progressText.Text = $"100% ({chosen.Count} of {chosen.Count})";
            status.Text = $"Scan complete: {found.Count} issues found";
        }
        catch (OperationCanceledException)
        {
            found.Clear();
            progress.Value = 0;
            progressText.Text = "";
            status.Text = "Scan cancelled. Nothing was changed.";
        }
        finally
        {
            cts.Dispose();
            cts = null;
            cancel.IsEnabled = false;
            scan.IsEnabled = true;
            Cursor = null;
        }
        list.ItemsSource = rows = [.. found.Select(i => new Row(i))];
        review.IsEnabled = rows.Count > 0;
    }

    void RunReview()
    {
        var chosen = rows.Where(r => r.IsChecked).Select(r => r.Issue).ToList();
        if (chosen.Count == 0) { status.Text = "Tick the issues to fix first."; return; }
        var owner = Window.GetWindow(this);
        // Backup is mandatory but silent: always written next to the settings, never asked for (no backup -> no fix).
        var backup = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(settings.Path)!, "RegistryBackups", RegFix.DefaultBackupName(DateTime.Now));
        try
        {
            System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(backup)!);
            RegFix.WriteBackup(chosen, backup);
        }
        catch (Exception e) when (e is System.IO.IOException or UnauthorizedAccessException) // WPF drops System.IO from implicit usings
        {
            Dialog.Info(owner, "Registry backup", $"The backup could not be written, so nothing was changed.\n{e.Message}", DialogKind.Error);
            return;
        }
        var fixer = new RegFixDialog(chosen) { Owner = owner };
        fixer.ShowDialog();
        var done = fixer.Fixed.ToHashSet();
        list.ItemsSource = rows = [.. rows.Where(r => !done.Contains(r.Issue))];
        review.IsEnabled = rows.Count > 0;
        status.Text = $"Fixed {fixer.Fixed.Count} issues" + (fixer.Failed > 0 ? $", {fixer.Failed} not fixed" : "") + $". Backup: {backup}";
    }

    // Writes the same Exclude list Options shows (REG entries) and drops the key's issues from the list.
    void Exclude(RegIssue i)
    {
        Custom.AddExclude(settings, "REG|" + i.Target);
        list.ItemsSource = rows = [.. rows.Where(r => r.Issue.Target != i.Target)];
        review.IsEnabled = rows.Count > 0;
        status.Text = $"Excluded: {i.Target}";
    }

    // Regedit opens at the key stored in its own LastKey setting.
    static void OpenInRegedit(string keyPath)
    {
        using var applet = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Applets\Regedit");
        applet.SetValue("LastKey", @"Computer\" + keyPath);
        Process.Start(new ProcessStartInfo("regedit.exe", "/m") { UseShellExecute = true });
    }
}
