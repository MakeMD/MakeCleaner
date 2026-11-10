using System.IO;
using System.Windows;
using System.Windows.Controls;

namespace MakeCleaner;

// Tools > Drive Wiper: wipe free space, or format + wipe a whole non-system drive (typed confirmation).
public partial class DriveWiperView : UserControl
{
    public const string ConfirmWord = "ERASE";
    readonly List<(DriveInfo Drive, CheckBox Box, bool? Ssd)> list = [];
    CancellationTokenSource? cts;

    public DriveWiperView()
    {
        InitializeComponent();
        foreach (var m in SecureDelete.Methods.Where(m => m.Passes > 0)) passes.Items.Add(m.Label);
        passes.SelectedIndex = 0;

        foreach (var d in DriveInfo.GetDrives().Where(d => d.IsReady && d.DriveType is DriveType.Fixed or DriveType.Removable))
        {
            var ssd = DriveWiper.IsSsd(d.Name);
            var tags = (DriveWiper.IsSystemDrive(d.Name) ? " (System)" : "") + (ssd == true ? " [SSD]" : "");
            var box = new CheckBox { Content = $"{d.Name}{tags}   {d.VolumeLabel}   {d.DriveFormat}   {Gb(d.AvailableFreeSpace)} free of {Gb(d.TotalSize)}", Margin = new Thickness(2, 4, 2, 4) };
            box.Checked += (_, _) => UpdateWarning(); // not Click: UI Automation toggles without a click
            box.Unchecked += (_, _) => UpdateWarning();
            drives.Items.Add(box);
            list.Add((d, box, ssd));
        }

        mode.SelectionChanged += (_, _) => UpdateWarning();
        wipe.Click += async (_, _) => await Run();
        cancel.Click += (_, _) => cts?.Cancel();
        UpdateWarning();
    }

    List<DriveInfo> Selected() => [.. list.Where(x => x.Box.IsChecked == true).Select(x => x.Drive)];
    bool Entire => mode.SelectedIndex == 1;

    void UpdateWarning()
    {
        var w = new List<string>();
        if (Entire) w.Add("WARNING: Entire Drive erases ALL data on the selected drives. The system drive cannot be erased.");
        if (list.Any(x => x.Box.IsChecked == true && x.Ssd != false))
            w.Add("Solid-state drives can wear out prematurely when securely wiped, and wiping does not reliably reach all of their cells.");
        warning.Text = string.Join(Environment.NewLine, w);
    }

    async Task Run()
    {
        var targets = Selected();
        if (targets.Count == 0) { progress.Text = "Select at least one drive."; return; }
        var n = SecureDelete.Methods.Where(m => m.Passes > 0).ElementAt(passes.SelectedIndex).Passes;
        var owner = Window.GetWindow(this);

        if (Entire)
        {
            var refused = targets.Select(d => DriveWiper.CheckErasable(d.Name, DriveWiper.SystemRoot, Path.GetPathRoot(AppContext.BaseDirectory)!)).FirstOrDefault(r => r != null);
            if (refused != null) { Dialog.Info(owner, "Drive Wiper", refused, DialogKind.Error); return; }
            if (!ToolsUi.RequireAdmin(this, "Erasing an entire drive")) return;
            var names = string.Join(", ", targets.Select(d => d.Name));
            if (Prompt(owner, $"All data on {names} will be permanently erased.\nType {ConfirmWord} to continue:") != ConfirmWord) return;
        }
        else if (!Dialog.Confirm(owner, "Drive Wiper", $"Wipe free space on {string.Join(", ", targets.Select(d => d.Name))} with {n} pass(es)? " +
                     "This can take a long time; the drive is temporarily filled.", "Wipe free space", DialogKind.Warning)) return;

        cts = new CancellationTokenSource();
        wipe.IsEnabled = false; cancel.IsEnabled = true;
        IProgress<string> report = new Progress<string>(s => progress.Text = s);
        try
        {
            foreach (var d in targets)
            {
                var root = d.Name;
                if (Entire)
                {
                    report.Report($"Formatting {root}");
                    await Task.Run(() => DriveWiper.Format(d));
                }
                await Task.Run(() => SecureDelete.WipeFreeSpace(DriveWiper.WipeDir(root), n,
                    new Progress<string>(s => report.Report($"Erasing {root}: {s}")), cts.Token));
            }
            progress.Text = "Drive Wiper complete.";
        }
        catch (OperationCanceledException) { progress.Text = "Cancelled. Temporary wipe files removed."; }
        catch (Exception e) { progress.Text = "Failed: " + e.Message; }
        finally { wipe.IsEnabled = true; cancel.IsEnabled = false; cts = null; }
    }

    // Typed-word confirmation; null = cancelled.
    static string? Prompt(Window? owner, string text)
    {
        var box = new TextBox { Margin = new Thickness(0, 10, 0, 12) };
        System.Windows.Automation.AutomationProperties.SetAutomationId(box, "confirmWord");
        var ok = new Button { Content = "Erase", IsDefault = true, Style = (Style)Application.Current.FindResource("Primary") };
        var no = new Button { Content = "Cancel", IsCancel = true, Margin = new Thickness(8, 0, 0, 0) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Children = { ok, no } };
        var body = new StackPanel { Margin = new Thickness(16), Children =
        {
            new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, Foreground = (System.Windows.Media.Brush)Application.Current.FindResource("Danger") },
            box, buttons,
        } };
        var dlg = new Window { Title = "Drive Wiper", Content = body, Owner = owner, Width = 440, SizeToContent = SizeToContent.Height,
            ResizeMode = ResizeMode.NoResize, WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
            Background = (System.Windows.Media.Brush)Application.Current.FindResource("Surface") };
        ok.Click += (_, _) => dlg.DialogResult = true;
        dlg.Loaded += (_, _) => box.Focus();
        return dlg.ShowDialog() == true ? box.Text.Trim() : null;
    }

    static string Gb(long b) => $"{b / (double)(1L << 30):0.#} GB";
}
