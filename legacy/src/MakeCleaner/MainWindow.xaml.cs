using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;

namespace MakeCleaner;

public partial class MainWindow : Window
{
    readonly CleanerView cleaner;
    readonly List<UIElement> pages;

    public MainWindow(Settings settings)
    {
        InitializeComponent();
        CheckNode.Confirm = (title, warning) =>
            Dialog.Confirm(this, title, warning, "Turn on", DialogKind.Warning);

        cleaner = new CleanerView(settings);
        // Rail sections: Cleaner, Registry, Tools (sub-menu), Options (sub-menu).
        var tools = new SubNavPage("Tools")
            .Add("Uninstall", () => new UninstallView())
            .Add("Startup", () => new StartupView())
            .Add("Duplicate Finder", () => new DuplicatesView())
            .Add("Disk Analyzer", () => new DiskAnalyzerView())
            .Add("Drive Wiper", () => new DriveWiperView())
            .Add("System Restore", () => new RestoreView());
        pages = [cleaner, new RegistryView(settings), tools, OptionsPages.Build(settings)];
        foreach (var (glyph, label) in new[] { ("", "Cleaner"), ("", "Registry"), ("", "Tools"), ("", "Options") })
        {
            var tile = new StackPanel();
            tile.Children.Add(new TextBlock { Text = glyph, FontFamily = (System.Windows.Media.FontFamily)FindResource("Icons"), FontSize = 22,
                                              HorizontalAlignment = HorizontalAlignment.Center });
            tile.Children.Add(new TextBlock { Text = label, FontSize = 12, Margin = new Thickness(0, 5, 0, 0), HorizontalAlignment = HorizontalAlignment.Center });
            var item = new ListBoxItem { Content = tile };
            AutomationProperties.SetName(item, label);
            nav.Items.Add(item);
        }
        nav.SelectionChanged += (_, _) => host.Content = pages[nav.SelectedIndex];
        nav.SelectedIndex = 0;

        var v = FileVersionInfo.GetVersionInfo(Environment.ProcessPath!).ProductVersion;
        version.Text = $"MakeCleaner {v}  ·  no telemetry, no ads, no network access";
        about.Click += (_, _) => Dialog.Info(this, "About MakeCleaner", OptionsPages.AboutText);
        Closing += (_, _) => cleaner.SaveChecks();
    }
}
