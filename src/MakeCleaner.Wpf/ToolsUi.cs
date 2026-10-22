using System.IO;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Microsoft.Win32;

namespace MakeCleaner;

// Shared helpers for the Tools pages (WPF twin of the WinForms ToolsUi).
public static class ToolsUi
{
    // Scan button doubles as Cancel; work runs off the UI thread, progress = files seen.
    // The count is sampled 5x a second: a Progress<T> per report posts hundreds of UI updates a second on a warm disk.
    public static async Task Run<T>(Button btn, TextBlock status, Func<CancellationToken, IProgress<int>, T> work, Action<T> done)
    {
        if (btn.Tag is CancellationTokenSource running) { running.Cancel(); return; }
        using var cts = new CancellationTokenSource();
        var idle = btn.Content;
        btn.Tag = cts;
        btn.Content = "Cancel";
        var seen = new Latest();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
        timer.Tick += (_, _) => status.Text = $"Scanning... {seen.Value:N0} files";
        status.Text = "Scanning...";
        timer.Start();
        try
        {
            var result = await Task.Run(() => work(cts.Token, seen));
            timer.Stop();
            done(result);
        }
        catch (OperationCanceledException) { timer.Stop(); status.Text = "Cancelled"; }
        finally { timer.Stop(); btn.Tag = null; btn.Content = idle; }
    }

    sealed class Latest : IProgress<int>
    {
        int value;
        public int Value => Volatile.Read(ref value);
        public void Report(int v) => Volatile.Write(ref value, v);
    }

    public static bool ConfirmDelete(DependencyObject owner, int count) =>
        MessageBox.Show(Window.GetWindow(owner), $"Delete {count} file(s)? This cannot be undone.", "MakeCleaner",
            MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) == MessageBoxResult.Yes;

    public static void OpenFolder(string file) => Process.Start("explorer.exe", $"/select,\"{file}\"");

    // Appends the picked folder to a "; "-separated path box.
    public static void PickFolder(TextBox box)
    {
        var d = new OpenFolderDialog();
        if (d.ShowDialog(Window.GetWindow(box)) == true) box.Text = box.Text.Length == 0 ? d.FolderName : $"{box.Text}; {d.FolderName}";
    }

    public static void SaveText(DependencyObject owner, string fileName, Func<string> text)
    {
        var d = new SaveFileDialog { Filter = "Text files (*.txt)|*.txt", FileName = fileName };
        if (d.ShowDialog(Window.GetWindow(owner)) == true) File.WriteAllText(d.FileName, text());
    }

    // Ask, relaunch elevated, close this copy. Returns false when not elevated and nothing happened.
    public static bool RequireAdmin(DependencyObject owner, string what)
    {
        if (Elevated.IsAdmin) return true;
        if (MessageBox.Show(Window.GetWindow(owner), $"{what} requires administrator rights. Restart MakeCleaner as administrator?",
                "MakeCleaner", MessageBoxButton.OKCancel, MessageBoxImage.Information) == MessageBoxResult.OK
            && Elevated.RelaunchAsAdmin())
            Application.Current.Shutdown();
        return false;
    }
}
