using System.Runtime.InteropServices;

namespace MakeCleaner;

// Tools > System Restore: list restore points, remove any but the most recent one. WMI denies both without admin.
public class RestorePanel : UserControl
{
    readonly ListView view = new() { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, MultiSelect = false, Name = "restorePoints" };
    readonly Label status = new() { Dock = DockStyle.Bottom, Height = 28, TextAlign = ContentAlignment.MiddleLeft, Name = "rpStatus" };
    readonly Button remove = new() { Text = "Remove", Width = 110, Enabled = false, Name = "rpRemove" };
    readonly Button admin = new() { Text = "Restart as administrator", AutoSize = true, Visible = false, Name = "rpAdmin" };
    List<RestorePoint> points = [];

    public RestorePanel()
    {
        view.Columns.Add("Description", 420);
        view.Columns.Add("Date", 160);
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 40, FlowDirection = FlowDirection.RightToLeft };
        buttons.Controls.AddRange([remove, admin]);
        Controls.AddRange([view, buttons, status]);

        view.SelectedIndexChanged += (_, _) => remove.Enabled = Picked() is { } p && RestorePoints.CanRemove(p, points);
        remove.Click += (_, _) => Remove();
        admin.Click += (_, _) => { if (Elevated.RelaunchAsAdmin()) Application.Exit(); };
        Load += (_, _) => Reload();
    }

    RestorePoint? Picked() => view.SelectedItems.Count == 1 ? (RestorePoint)view.SelectedItems[0].Tag! : null;

    void Reload()
    {
        view.Items.Clear();
        remove.Enabled = false;
        try { points = RestorePoints.List(); }
        catch (UnauthorizedAccessException e) { status.Text = e.Message; admin.Visible = true; return; }
        catch (COMException e) { status.Text = "System Restore unavailable: " + e.Message; return; }
        foreach (var p in points.OrderByDescending(p => p.Seq))
            view.Items.Add(new ListViewItem([p.Description, p.Created.ToLocalTime().ToString("g")]) { Tag = p });
        status.Text = points.Count == 0 ? "No restore points." : $"{points.Count} restore point(s). The most recent one cannot be removed.";
    }

    void Remove()
    {
        if (Picked() is not { } p || !RestorePoints.CanRemove(p, points)) return;
        if (MessageBox.Show(this, $"Remove restore point \"{p.Description}\"?", "System Restore",
                MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK) return;
        if (!ElevatedUi.Require(this, "Removing a restore point")) return;
        var rc = RestorePoints.Remove(p.Seq);
        Reload();
        if (rc != 0) status.Text = $"Removing failed (error {rc}).";
    }
}
