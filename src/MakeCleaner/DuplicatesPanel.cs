namespace MakeCleaner;

public class DuplicatesPanel : UserControl
{
    readonly CheckBox byName = new() { Text = "Name", Checked = true, AutoSize = true };
    readonly CheckBox bySize = new() { Text = "Size", Checked = true, AutoSize = true };
    readonly CheckBox byDate = new() { Text = "Modified date", Checked = true, AutoSize = true };
    readonly CheckBox byContent = new() { Text = "Content", AutoSize = true };
    readonly CheckBox noEmpty = new() { Text = "Zero-byte", Checked = true, AutoSize = true };
    readonly CheckBox noSystem = new() { Text = "System", Checked = true, AutoSize = true };
    readonly CheckBox noHidden = new() { Text = "Hidden", Checked = true, AutoSize = true };
    readonly CheckBox noReadOnly = new() { Text = "Read-only", AutoSize = true };
    readonly NumericUpDown minMb = new() { Maximum = 1_000_000, Width = 70 };
    readonly NumericUpDown maxMb = new() { Maximum = 1_000_000, Width = 70 };
    readonly TextBox include, exclude;
    readonly ListView list = new() { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, CheckBoxes = true, Name = "dupList" };
    readonly Label status = new() { Dock = DockStyle.Bottom, Height = 24, TextAlign = ContentAlignment.MiddleLeft, Name = "dupStatus" };
    readonly Button search = new() { Text = "Search", Width = 110, Name = "dupSearch" };

    public DuplicatesPanel()
    {
        var match = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(4) };
        match.Controls.AddRange([new Label { Text = "Match by:", AutoSize = true, Padding = new Padding(0, 4, 0, 0) }, byName, bySize, byDate, byContent,
            new Label { Text = "Ignore:", AutoSize = true, Padding = new Padding(12, 4, 0, 0) }, noEmpty, noSystem, noHidden, noReadOnly,
            new Label { Text = "Size MB from", AutoSize = true, Padding = new Padding(12, 4, 0, 0) }, minMb,
            new Label { Text = "to (0 = any)", AutoSize = true, Padding = new Padding(0, 4, 0, 0) }, maxMb]);
        (include, var incRow) = ToolsUi.PathRow("Include", "dupInclude", Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        (exclude, var excRow) = ToolsUi.PathRow("Exclude", "dupExclude", Environment.GetFolderPath(Environment.SpecialFolder.Windows));

        list.Columns.Add("Name", 220);
        list.Columns.Add("Folder", 380);
        list.Columns.Add("Size", 90, HorizontalAlignment.Right);
        list.Columns.Add("Modified", 140);
        list.ItemActivate += (_, _) => { if (list.FocusedItem?.Tag is FileInfo f) ToolsUi.OpenFolder(f.FullName); };

        var selectDupes = new Button { Text = "Select all but first", Width = 140 };
        var delete = new Button { Text = "Delete Selected", Width = 120, Name = "dupDelete" };
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 36, FlowDirection = FlowDirection.RightToLeft };
        buttons.Controls.AddRange([delete, selectDupes, search]);
        Controls.AddRange([list, excRow, incRow, match, buttons, status]);

        search.Click += async (_, _) => await ToolsUi.Run(search, status, "Search", (ct, p) => Duplicates.Find(Options(), ct, p), Show);
        selectDupes.Click += (_, _) =>
        {
            foreach (ListViewGroup g in list.Groups)
                for (int i = 0; i < g.Items.Count; i++) g.Items[i].Checked = i > 0;
        };
        delete.Click += (_, _) => Delete();
    }

    DupOptions Options() => new()
    {
        Include = Scan.SplitPaths(include.Text),
        Exclude = Scan.SplitPaths(exclude.Text),
        ByName = byName.Checked, BySize = bySize.Checked, ByDate = byDate.Checked, ByContent = byContent.Checked,
        IgnoreEmpty = noEmpty.Checked, IgnoreSystem = noSystem.Checked, IgnoreHidden = noHidden.Checked, IgnoreReadOnly = noReadOnly.Checked,
        MinSize = (long)minMb.Value << 20,
        MaxSize = maxMb.Value == 0 ? long.MaxValue : (long)maxMb.Value << 20,
    };

    void Show(DupResult r)
    {
        list.BeginUpdate();
        list.Items.Clear();
        list.Groups.Clear();
        // ponytail: capped at 2000 groups; virtual mode if someone has more
        foreach (var (g, i) in r.Groups.OrderByDescending(g => g[0].Length * (g.Count - 1)).Take(2000).Select((g, i) => (g, i)))
        {
            var group = new ListViewGroup($"#{i + 1}: {g.Count} x {MainForm.Fmt(g[0].Length)}");
            list.Groups.Add(group);
            foreach (var f in g)
                list.Items.Add(new ListViewItem([f.Name, f.DirectoryName ?? "", MainForm.Fmt(f.Length), f.LastWriteTime.ToString("g")], group) { Tag = f });
        }
        list.EndUpdate();
        var wasted = r.Groups.Sum(g => g[0].Length * (g.Count - 1));
        status.Text = $"Found {r.Groups.Count} duplicate groups, {r.Groups.Sum(g => g.Count)} files, {MainForm.Fmt(wasted)} reclaimable";
    }

    void Delete()
    {
        var items = list.CheckedItems.Cast<ListViewItem>().ToList();
        if (items.Count == 0 || !ToolsUi.ConfirmDelete(this, items.Count)) return;
        var r = Engine.Clean(items.Select(i => (FileInfo)i.Tag!));
        foreach (var i in items.Where(i => !((FileInfo)i.Tag!).Exists)) list.Items.Remove(i);
        status.Text = $"Deleted {r.Deleted} files, {MainForm.Fmt(r.BytesFreed)} freed, {r.Skipped} skipped";
    }
}
