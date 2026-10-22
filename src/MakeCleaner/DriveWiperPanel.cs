namespace MakeCleaner;

// Tools > Drive Wiper: wipe free space, or format + wipe a whole non-system drive.
public class DriveWiperPanel : UserControl
{
    public const string ConfirmWord = "ERASE";
    readonly CheckedListBox drives = new() { Dock = DockStyle.Fill, CheckOnClick = true, Name = "drives" };
    readonly ComboBox mode = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 300, Name = "wipeMode" };
    readonly ComboBox passes = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 300, Name = "wipePasses" };
    readonly Label warning = new() { AutoSize = true, ForeColor = Color.Firebrick, MaximumSize = new Size(560, 0), Name = "wipeWarning" };
    readonly Label progress = new() { AutoSize = true, Name = "wipeProgress" };
    readonly Button wipe = new() { Text = "Wipe", Width = 110, Name = "wipe" };
    readonly Button cancel = new() { Text = "Cancel", Width = 110, Enabled = false, Name = "wipeCancel" };
    readonly List<DriveInfo> list = [];
    readonly Dictionary<string, bool?> ssd = [];
    CancellationTokenSource? cts;

    public DriveWiperPanel()
    {
        mode.Items.AddRange(["Free Space Only", "Entire Drive (All data will be erased)"]);
        mode.SelectedIndex = 0;
        foreach (var m in SecureDelete.Methods.Where(m => m.Passes > 0)) passes.Items.Add(m.Label);
        passes.SelectedIndex = 0;

        foreach (var d in DriveInfo.GetDrives().Where(d => d.IsReady && d.DriveType is DriveType.Fixed or DriveType.Removable))
        {
            list.Add(d);
            ssd[d.Name] = DriveWiper.IsSsd(d.Name);
            var tags = (DriveWiper.IsSystemDrive(d.Name) ? " (System)" : "") + (ssd[d.Name] == true ? " [SSD]" : "");
            drives.Items.Add($"{d.Name}{tags}  {d.VolumeLabel}  {d.DriveFormat}  {Gb(d.AvailableFreeSpace)} free of {Gb(d.TotalSize)}");
        }

        drives.ItemCheck += (_, _) => BeginInvoke(UpdateWarning);
        mode.SelectedIndexChanged += (_, _) => UpdateWarning();
        wipe.Click += async (_, _) => await Run();
        cancel.Click += (_, _) => cts?.Cancel();

        var top = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 150, FlowDirection = FlowDirection.TopDown, Padding = new Padding(8) };
        top.Controls.AddRange([new Label { Text = "Securely erase the free space or the contents of a drive", AutoSize = true },
            new Label { Text = "Wipe:", AutoSize = true }, mode, new Label { Text = "Security:", AutoSize = true }, passes]);
        var bottom = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 90, FlowDirection = FlowDirection.TopDown, Padding = new Padding(8) };
        var buttons = new FlowLayoutPanel { AutoSize = true };
        buttons.Controls.AddRange([wipe, cancel]);
        bottom.Controls.AddRange([warning, buttons, progress]);
        Controls.AddRange([drives, top, bottom]);
        UpdateWarning();
    }

    List<DriveInfo> Selected() => [.. list.Where((_, i) => drives.GetItemChecked(i))];
    bool Entire => mode.SelectedIndex == 1;

    void UpdateWarning()
    {
        var w = new List<string>();
        if (Entire) w.Add("WARNING: Entire Drive erases ALL data on the selected drives. The system drive cannot be selected.");
        if (Selected().Any(d => ssd[d.Name] != false))
            w.Add("Solid-state drives can wear out prematurely when securely wiped, and wiping does not reliably reach all of their cells.");
        warning.Text = string.Join(Environment.NewLine, w);
    }

    async Task Run()
    {
        var targets = Selected();
        if (targets.Count == 0) { progress.Text = "Select at least one drive."; return; }
        var n = SecureDelete.Methods.Where(m => m.Passes > 0).ElementAt(passes.SelectedIndex).Passes;

        if (Entire)
        {
            var refused = targets.Select(d => DriveWiper.CheckErasable(d.Name, DriveWiper.SystemRoot, Path.GetPathRoot(AppContext.BaseDirectory)!)).FirstOrDefault(r => r != null);
            if (refused != null) { MessageBox.Show(this, refused, "Drive Wiper", MessageBoxButtons.OK, MessageBoxIcon.Stop); return; }
            if (!ElevatedUi.Require(this, "Erasing an entire drive")) return;
            var names = string.Join(", ", targets.Select(d => d.Name));
            if (Prompt($"All data on {names} will be permanently erased.\nType {ConfirmWord} to continue:") != ConfirmWord) return;
        }
        else if (MessageBox.Show(this, $"Wipe free space on {string.Join(", ", targets.Select(d => d.Name))} with {n} pass(es)? " +
                     "This can take a long time; the drive is temporarily filled.", "Drive Wiper",
                     MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK) return;

        cts = new CancellationTokenSource();
        wipe.Enabled = false; cancel.Enabled = true;
        var report = new Progress<string>(s => progress.Text = s);
        try
        {
            foreach (var d in targets)
            {
                var root = d.Name;
                if (Entire)
                {
                    ((IProgress<string>)report).Report($"Formatting {root}");
                    await Task.Run(() => DriveWiper.Format(d));
                }
                await Task.Run(() => SecureDelete.WipeFreeSpace(DriveWiper.WipeDir(root), n,
                    new Progress<string>(s => ((IProgress<string>)report).Report($"Erasing {root}: {s}")), cts.Token));
            }
            progress.Text = "Drive Wiper complete.";
        }
        catch (OperationCanceledException) { progress.Text = "Cancelled. Temporary wipe files removed."; }
        catch (Exception e) { progress.Text = "Failed: " + e.Message; }
        finally { wipe.Enabled = true; cancel.Enabled = false; cts = null; }
    }

    static string? Prompt(string text)
    {
        using var f = new Form { Text = "Drive Wiper", FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent,
            ClientSize = new Size(420, 130), MinimizeBox = false, MaximizeBox = false };
        var box = new TextBox { Left = 12, Top = 60, Width = 396, Name = "confirmWord" };
        var ok = new Button { Text = "Erase", Left = 252, Top = 92, DialogResult = DialogResult.OK };
        var no = new Button { Text = "Cancel", Left = 333, Top = 92, DialogResult = DialogResult.Cancel };
        f.Controls.AddRange([new Label { Text = text, Left = 12, Top = 10, Width = 396, Height = 46, ForeColor = Color.Firebrick }, box, ok, no]);
        f.AcceptButton = ok; f.CancelButton = no;
        return f.ShowDialog() == DialogResult.OK ? box.Text.Trim() : null;
    }

    static string Gb(long b) => $"{b / (double)(1L << 30):0.#} GB";
}
