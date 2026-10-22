using System.IO;
using System.Windows;
using Microsoft.Win32;

namespace MakeCleaner;

// Shared bits of the Tools pages.
public static class ToolsUi
{
    // "Save to text file": header + one tab-separated line per row.
    public static void SaveText(DependencyObject owner, string name, IEnumerable<string> lines)
    {
        var dlg = new SaveFileDialog { FileName = $"MakeCleaner {name}.txt", Filter = "Text files (*.txt)|*.txt" };
        if (dlg.ShowDialog(Window.GetWindow(owner)) == true) File.WriteAllLines(dlg.FileName, lines);
    }

    public static bool Confirm(DependencyObject owner, string text, string title) =>
        MessageBox.Show(Window.GetWindow(owner), text, title, MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) == MessageBoxResult.Yes;

    public static void Info(DependencyObject owner, string text, string title) =>
        MessageBox.Show(Window.GetWindow(owner), text, title);
}
