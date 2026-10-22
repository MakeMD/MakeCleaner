using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;

namespace MakeCleaner;

// Tools > System Restore: list restore points, remove any but the most recent one. WMI denies both without admin.
public partial class RestoreView : UserControl
{
    List<RestorePoint> points = [];

    public RestoreView()
    {
        InitializeComponent();
        view.SelectionChanged += (_, _) => remove.IsEnabled = Picked() is { } p && RestorePoints.CanRemove(p, points);
        remove.Click += (_, _) => Remove();
        admin.Click += (_, _) => { if (Elevated.RelaunchAsAdmin()) Application.Current.Shutdown(); };
        Loaded += (_, _) => Reload();
    }

    RestorePoint? Picked() => (view.SelectedItem as Row)?.Point;

    void Reload()
    {
        view.ItemsSource = null;
        remove.IsEnabled = false;
        try { points = RestorePoints.List(); }
        catch (UnauthorizedAccessException e) { status.Text = e.Message; admin.Visibility = Visibility.Visible; return; }
        catch (COMException e) { status.Text = "System Restore unavailable: " + e.Message; return; }
        view.ItemsSource = points.OrderByDescending(p => p.Seq).Select(p => new Row(p)).ToList();
        status.Text = points.Count == 0 ? "No restore points." : $"{points.Count} restore point(s). The most recent one cannot be removed.";
    }

    void Remove()
    {
        if (Picked() is not { } p || !RestorePoints.CanRemove(p, points)) return;
        if (MessageBox.Show(Window.GetWindow(this), $"Remove restore point \"{p.Description}\"?", "System Restore",
                MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        if (!ToolsUi.RequireAdmin(this, "Removing a restore point")) return;
        var rc = RestorePoints.Remove(p.Seq);
        Reload();
        if (rc != 0) status.Text = $"Removing failed (error {rc}).";
    }

    public record Row(RestorePoint Point)
    {
        public string Description => Point.Description;
        public string Date => Point.Created.ToLocalTime().ToString("g");
    }
}
