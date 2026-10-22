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
            MessageBox.Show(this, warning, title, MessageBoxButton.OKCancel, MessageBoxImage.Warning) == MessageBoxResult.OK;

        cleaner = new CleanerView(settings);
        // Rail sections; Registry / Tools / Options get their screens in tickets 15-18.
        pages = [cleaner, new SubNavPage("Registry"), new SubNavPage("Tools"), OptionsPages.Build(settings)];
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
        about.Click += (_, _) => MessageBox.Show(this, OptionsPages.AboutText, "About MakeCleaner");
        Closing += (_, _) => cleaner.SaveChecks();
    }
}
