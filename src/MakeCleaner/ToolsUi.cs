using System.Diagnostics;

namespace MakeCleaner;

// Shared helpers for the Tools panels.
public static class ToolsUi
{
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
