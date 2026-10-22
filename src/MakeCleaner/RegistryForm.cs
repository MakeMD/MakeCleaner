using System.Diagnostics;
using Microsoft.Win32;

namespace MakeCleaner;

// Registry section: Scan -> review -> mandatory .reg backup -> Fix.
public class RegistryForm : Form
{
    const string ExcludeKey = "RegistryExclude"; // '|'-separated key/value paths
    readonly Settings settings;
    readonly CheckedListBox cats = new() { Dock = DockStyle.Left, Width = 220, CheckOnClick = true, Name = "regcats" };
    readonly ListView list = new() { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, CheckBoxes = true, Name = "reglist" };
    readonly Label status = new() { Dock = DockStyle.Bottom, Height = 28, TextAlign = ContentAlignment.MiddleLeft, Name = "regstatus" };
    readonly Button scan = new() { Text = "Scan for Issues", Width = 130, Name = "regscan" };
    readonly Button fix = new() { Text = "Fix selected...", Width = 130, Enabled = false, Name = "regfix" };
    List<RegIssue> issues = [];

    public RegistryForm(Settings settings)
    {
        this.settings = settings;
        Text = "MakeCleaner - Registry";
        ClientSize = new Size(1000, 600);
        StartPosition = FormStartPosition.CenterParent;

        foreach (var c in RegScanner.Categories) cats.Items.Add(c.Name, settings.GetBool("Reg:" + c.Name, true));
        list.Columns.Add("Problem", 200);
        list.Columns.Add("Data", 360);
        list.Columns.Add("Registry key", 420);

        var menu = new ContextMenuStrip();
        menu.Items.Add("Open in RegEdit", null, (_, _) => { if (Selected() is { } i) OpenInRegedit(i.KeyPath); });
        menu.Items.Add("Add to Exclude list", null, (_, _) => { if (Selected() is { } i) Exclude(i); });
        list.ContextMenuStrip = menu;

        var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 40, FlowDirection = FlowDirection.RightToLeft };
        buttons.Controls.AddRange([fix, scan]);
        Controls.AddRange([list, cats, buttons, status]);

        scan.Click += async (_, _) => await RunScan();
        fix.Click += (_, _) => RunFix();
        FormClosing += (_, _) =>
        {
            for (int i = 0; i < cats.Items.Count; i++) settings.Set("Reg:" + RegScanner.Categories[i].Name, cats.GetItemChecked(i));
            settings.Save();
        };
    }

    List<string> Excluded() => [.. settings.Get(ExcludeKey).Split('|', StringSplitOptions.RemoveEmptyEntries)];

    RegIssue? Selected() => list.SelectedItems.Count == 1 ? (RegIssue)list.SelectedItems[0].Tag! : null;

    async Task RunScan()
    {
        scan.Enabled = fix.Enabled = false;
        status.Text = "Scanning...";
        UseWaitCursor = true;
        var selected = RegScanner.Categories.Where((_, i) => cats.GetItemChecked(i)).ToList();
        var excluded = Excluded();
        issues = await Task.Run(() => RegScanner.ForThisPc().Scan(selected, excluded));
        list.BeginUpdate();
        list.Items.Clear();
        foreach (var i in issues)
            list.Items.Add(new ListViewItem([i.Problem, i.Data, i.Target]) { Tag = i, Checked = true });
        list.EndUpdate();
        UseWaitCursor = false;
        scan.Enabled = true;
        fix.Enabled = issues.Count > 0;
        status.Text = $"Scan complete: {issues.Count} issues found";
    }

    void RunFix()
    {
        var chosen = list.CheckedItems.Cast<ListViewItem>().Select(it => (RegIssue)it.Tag!).ToList();
        if (chosen.Count == 0) return;
        using var dlg = new SaveFileDialog
        {
            Title = "Back up the registry before fixing (required)",
            Filter = "Reg Files (*.reg)|*.reg",
            FileName = RegFix.DefaultBackupName(DateTime.Now),
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
        };
        if (dlg.ShowDialog(this) != DialogResult.OK) return; // no backup -> no fix
        RegFix.Result r;
        try { r = RegFix.Fix(chosen, dlg.FileName); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            MessageBox.Show(this, $"Backup failed, nothing was changed.\n{e.Message}", Text, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        foreach (var it in list.CheckedItems.Cast<ListViewItem>().ToList()) list.Items.Remove(it);
        issues = [.. list.Items.Cast<ListViewItem>().Select(it => (RegIssue)it.Tag!)];
        fix.Enabled = issues.Count > 0;
        status.Text = $"Fixed {r.Fixed} issues, {r.Failed} failed (need admin?). Backup: {dlg.FileName}";
    }

    void Exclude(RegIssue i)
    {
        settings.Set(ExcludeKey, string.Join("|", Excluded().Append(i.Target).Distinct(StringComparer.OrdinalIgnoreCase)));
        settings.Save();
        foreach (var it in list.Items.Cast<ListViewItem>().Where(it => ((RegIssue)it.Tag!).Target == i.Target).ToList()) list.Items.Remove(it);
        status.Text = $"Excluded: {i.Target}";
    }

    // Regedit opens at the key stored in its own LastKey setting.
    static void OpenInRegedit(string keyPath)
    {
        using var applet = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Applets\Regedit");
        applet.SetValue("LastKey", @"Computer\" + keyPath);
        Process.Start(new ProcessStartInfo("regedit.exe", "/m") { UseShellExecute = true });
    }
}
