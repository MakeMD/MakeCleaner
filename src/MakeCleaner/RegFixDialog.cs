using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace MakeCleaner;

// The n/N stepper shown after the backup is written: look at one issue at a time, fix it, fix all, or close.
// Fixed issues stay in the walk (marked) so the counter never jumps; Fixed/Failed are read by RegistryView afterwards.
public class RegFixDialog : Window
{
    public List<RegIssue> Fixed { get; } = [];
    public int Failed => failed.Count;
    readonly HashSet<RegIssue> failed = [];

    readonly List<RegIssue> issues;
    readonly TextBlock counter = new() { FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock details = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 12, 0, 12) };
    readonly Button prev = Btn("<<", "regprev", 50), next = Btn(">>", "regnext", 50);
    readonly Button fixOne = Btn("Fix Issue", "regfixone"), fixAll = Btn("Fix All Selected", "regfixall"), close = Btn("Close", "regclose");
    int at;

    public RegFixDialog(List<RegIssue> issues)
    {
        this.issues = issues;
        Title = "Fix registry issues";
        Width = 560;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = (System.Windows.Media.Brush)FindResource("Bg");
        fixAll.Style = (Style)FindResource("Primary");

        var nav = new DockPanel();
        DockPanel.SetDock(prev, Dock.Left);
        DockPanel.SetDock(next, Dock.Right);
        counter.Margin = new Thickness(12, 0, 12, 0);
        nav.Children.Add(prev);
        nav.Children.Add(next);
        nav.Children.Add(counter);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        foreach (var b in new[] { fixOne, fixAll, close }) { b.Margin = new Thickness(8, 0, 0, 0); buttons.Children.Add(b); }
        Content = new StackPanel { Margin = new Thickness(18), Children = { nav, details, buttons } };

        prev.Click += (_, _) => Show(at - 1);
        next.Click += (_, _) => Show(at + 1);
        close.Click += (_, _) => Close();
        fixOne.Click += (_, _) =>
        {
            Apply([issues[at]]);
            var left = Enumerable.Range(1, issues.Count).Select(d => (at + d) % issues.Count).Where(i => !Fixed.Contains(issues[i]));
            if (left.Any()) Show(left.First()); else Close();
        };
        fixAll.Click += (_, _) =>
        {
            var left = issues.Where(i => !Fixed.Contains(i)).ToList();
            if (MessageBox.Show(this, $"Fix all {left.Count} remaining issues? The backup you just saved can undo this.",
                    "Fix All Selected", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
            Apply(left);
            Close();
        };
        Show(0);
    }

    static Button Btn(string text, string id, double minWidth = 110)
    {
        var b = new Button { Content = text, MinWidth = minWidth };
        AutomationProperties.SetAutomationId(b, id);
        return b;
    }

    // One at a time, so we know exactly which ones failed (they stay in the walk, unfixed, and can be retried).
    void Apply(List<RegIssue> batch)
    {
        foreach (var i in batch)
            if (RegFix.Apply([i]).Fixed == 1) { Fixed.Add(i); failed.Remove(i); }
            else failed.Add(i);
    }

    void Show(int i)
    {
        at = (i + issues.Count) % issues.Count;
        var x = issues[at];
        var done = Fixed.Contains(x);
        counter.Text = $"Issue {at + 1} of {issues.Count}" + (done ? "  -  fixed" : failed.Contains(x) ? "  -  failed (need admin?)" : "");
        details.Text = $"Problem: {x.Problem}\nData: {x.Data}\nRegistry key: {x.Target}\n\n" +
                       $"Solution: delete the registry {(x.ValueName == null ? "key" : "value")}.";
        prev.IsEnabled = next.IsEnabled = issues.Count > 1;
        fixOne.IsEnabled = !done;
        fixAll.IsEnabled = issues.Any(j => !Fixed.Contains(j));
    }
}
