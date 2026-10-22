using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;

namespace MakeCleaner;

// Tools and Options: a vertical sub-menu on the left, the selected page on the right.
// Adding a page is one line: page.Add("Uninstall", () => new UninstallView()). Pages are built on first open.
public class SubNavPage : DockPanel
{
    readonly ListBox list = new();
    readonly ContentControl host = new() { Margin = new Thickness(16) };
    readonly List<(Func<UIElement> Make, UIElement? Made)> pages = [];

    public SubNavPage(string name)
    {
        list.Style = (Style)Application.Current.FindResource("SubNav");
        AutomationProperties.SetAutomationId(list, name + "Nav");
        SetDock(list, Dock.Left);
        Children.Add(list);
        Children.Add(host);
        host.Content = new TextBlock
        {
            Text = $"{name} is still in the classic MakeCleaner window; it moves here next.",
            Foreground = (System.Windows.Media.Brush)Application.Current.FindResource("Muted"),
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        };
        list.Visibility = Visibility.Collapsed; // until the first page arrives
        list.SelectionChanged += (_, _) =>
        {
            var i = list.SelectedIndex;
            if (i < 0) return;
            var (make, made) = pages[i];
            made ??= make();
            pages[i] = (make, made);
            host.Content = made;
        };
    }

    public SubNavPage Add(string title, Func<UIElement> make)
    {
        list.Visibility = Visibility.Visible;
        pages.Add((make, null));
        list.Items.Add(new ListBoxItem { Content = title });
        if (list.SelectedIndex < 0) list.SelectedIndex = 0;
        return this;
    }
}
