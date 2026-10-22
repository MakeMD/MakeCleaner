using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace MakeCleaner;

public enum DialogKind { Info, Question, Warning, Error }

// Themed replacement for MessageBox: same palette and buttons as the rest of the app (Theme.xaml),
// and buttons that say what they do ("Close Chrome" / "Skip") instead of the OS's localized Yes/No.
public static class Dialog
{
    // buttons[0] is the primary (default) action; the last one is Esc when there is more than one.
    // Returns the index of the clicked button, -1 when the window is closed.
    public static int Show(DependencyObject owner, string title, string text, DialogKind kind, params string[] buttons)
    {
        var app = Application.Current;
        var win = new Window
        {
            Title = title, Owner = Window.GetWindow(owner), Width = 480, SizeToContent = SizeToContent.Height,
            ResizeMode = ResizeMode.NoResize, WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
            Background = (Brush)app.FindResource("Surface"),
        };
        AutomationProperties.SetAutomationId(win, "dialog");

        var (glyph, color) = kind switch
        {
            DialogKind.Warning => ("", "Danger"),
            DialogKind.Error => ("", "Danger"),
            DialogKind.Question => ("", "Accent"),
            _ => ("", "Accent"),
        };
        var icon = new TextBlock
        {
            Text = glyph, FontFamily = (FontFamily)app.FindResource("Icons"), FontSize = 28, Margin = new Thickness(0, 0, 16, 0),
            Foreground = (Brush)app.FindResource(color), VerticalAlignment = VerticalAlignment.Top,
        };
        var message = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, FontSize = 14, Foreground = (Brush)app.FindResource("Text") };
        AutomationProperties.SetAutomationId(message, "dialogText");
        var body = new DockPanel { Margin = new Thickness(22, 22, 22, 18) };
        DockPanel.SetDock(icon, Dock.Left);
        body.Children.Add(icon);
        body.Children.Add(message);

        int result = -1;
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        for (int i = 0; i < buttons.Length; i++)
        {
            int index = i;
            var b = new Button { Content = buttons[i], MinWidth = 96, Margin = new Thickness(8, 0, 0, 0), IsDefault = i == 0, IsCancel = i > 0 && i == buttons.Length - 1 };
            if (i == 0) b.Style = (Style)app.FindResource("Primary");
            AutomationProperties.SetAutomationId(b, $"dialogButton{i}");
            b.Click += (_, _) => { result = index; win.DialogResult = true; };
            row.Children.Add(b);
        }
        var footer = new Border
        {
            Background = (Brush)app.FindResource("Bg"), BorderBrush = (Brush)app.FindResource("Line"),
            BorderThickness = new Thickness(0, 1, 0, 0), Padding = new Thickness(16, 12, 16, 12), Child = row,
        };
        win.Content = new StackPanel { Children = { body, footer } };
        win.ShowDialog();
        return result;
    }

    public static bool Confirm(DependencyObject owner, string title, string text, string action, DialogKind kind = DialogKind.Question) =>
        Show(owner, title, text, kind, action, "Cancel") == 0;

    public static void Info(DependencyObject owner, string title, string text, DialogKind kind = DialogKind.Info) =>
        Show(owner, title, text, kind, "OK");
}
