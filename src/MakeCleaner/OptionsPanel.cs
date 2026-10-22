namespace MakeCleaner;

// Options section. Saved immediately on change.
public class OptionsPanel : UserControl
{
    public const string SecureDeleteKey = "SecureDeletePasses";
    static readonly string[] IncludeModes = ["Files only", "Files and subfolders", "Files, subfolders and the folder itself"];
    static readonly string[] ExcludeKinds = ["Folder", "File", "Registry key"];

    readonly Settings settings;

    public OptionsPanel(Settings settings)
    {
        this.settings = settings;
        var method = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 320, Name = "secureDelete" };
        foreach (var m in SecureDelete.Methods) method.Items.Add(m.Label);
        var current = settings.GetInt(SecureDeleteKey, 0);
        method.SelectedIndex = Math.Max(0, Array.FindIndex(SecureDelete.Methods, m => m.Passes == current));
        method.SelectedIndexChanged += (_, _) =>
        {
            settings.Set(SecureDeleteKey, SecureDelete.Methods[method.SelectedIndex].Passes);
            settings.Save();
        };

        var layout = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, Padding = new Padding(12), AutoScroll = true, WrapContents = false };
        layout.Controls.Add(new Label { Text = "Secure Deletion (applies to every clean)", AutoSize = true });
        layout.Controls.Add(method);
        layout.Controls.Add(IncludeGroup());
        layout.Controls.Add(ExcludeGroup());
        Controls.Add(layout);
    }

    GroupBox IncludeGroup()
    {
        var list = new ListBox { Width = 640, Height = 90, Name = "incList" };
        var path = new TextBox { Width = 440, Name = "incPath", PlaceholderText = @"Folder or file, e.g. D:\Logs" };
        var mode = Combo("incMode", IncludeModes, 1);
        var pattern = new TextBox { Width = 120, Text = "*.*", Name = "incPattern" };
        var age = new NumericUpDown { Width = 70, Maximum = 87600, Name = "incAge" };
        var add = new Button { Text = "Add", Name = "incAdd" };
        var remove = new Button { Text = "Remove", Name = "incRemove" };
        var status = new Label { AutoSize = true, Name = "incStatus" };
        void Reload() => Fill(list, Custom.IncludePrefix);

        add.Click += (_, _) =>
        {
            var p = path.Text.Trim();
            if (Custom.Reject(p) is { } why) { status.Text = why; return; }
            var full = Path.GetFullPath(Environment.ExpandEnvironmentVariables(p));
            string entry;
            if (File.Exists(full)) entry = $"{Path.GetDirectoryName(full)}|{Path.GetFileName(full)}";
            else if (Directory.Exists(full))
                entry = $"{full}|{(pattern.Text.Trim().Length > 0 ? pattern.Text.Trim() : "*.*")}"
                        + mode.SelectedIndex switch { 1 => "|RECURSE", 2 => "|REMOVESELF", _ => "" };
            else { status.Text = "Folder or file not found."; return; }
            if (age.Value > 0) entry += $"|OLDER={age.Value}";
            Append(Custom.IncludePrefix, entry);
            Reload();
            path.Clear();
            status.Text = $"Added. Tick \"{Custom.RuleName}\" in Cleaner > Windows to clean it.";
        };
        remove.Click += (_, _) => { RemoveSelected(list, Custom.IncludePrefix); Reload(); };
        Reload();

        return Group("Include (extra files and folders to clean)", list,
            Row(path, Browse(path), add, remove),
            Row(new Label { Text = "Mode:", AutoSize = true }, mode, new Label { Text = "Mask:", AutoSize = true }, pattern,
                new Label { Text = "Only older than (hours, 0 = any):", AutoSize = true }, age),
            status);
    }

    GroupBox ExcludeGroup()
    {
        var list = new ListBox { Width = 640, Height = 90, Name = "excList" };
        var path = new TextBox { Width = 300, Name = "excPath", PlaceholderText = @"Folder, file or HKCU\Software\Key[|Value]" };
        var kind = Combo("excKind", ExcludeKinds, 0, 130);
        var add = new Button { Text = "Add", Name = "excAdd" };
        var remove = new Button { Text = "Remove", Name = "excRemove" };
        var status = new Label { AutoSize = true, Name = "excStatus" };
        void Reload() => Fill(list, Custom.ExcludePrefix);

        add.Click += (_, _) =>
        {
            var p = path.Text.Trim();
            var x = Environment.ExpandEnvironmentVariables(p);
            var full = Path.IsPathFullyQualified(x);
            string? entry = kind.SelectedIndex switch
            {
                0 when full && Directory.Exists(x) => "PATH|" + Path.GetFullPath(x).TrimEnd('\\'),
                1 when full && File.Exists(x) => $"FILE|{Path.GetDirectoryName(Path.GetFullPath(x))}|{Path.GetFileName(x)}",
                2 when p.StartsWith("HK", StringComparison.OrdinalIgnoreCase) && p.Contains('\\') => "REG|" + p,
                _ => null,
            };
            if (entry == null) { status.Text = kind.SelectedIndex == 2 ? @"Use a key like HKCU\Software\Key or HKCU\Software\Key|Value." : "Not found."; return; }
            Custom.AddExclude(settings, entry);
            Reload();
            path.Clear();
            status.Text = "Added. Excluded items are skipped by every cleaner.";
        };
        remove.Click += (_, _) => { RemoveSelected(list, Custom.ExcludePrefix); Reload(); };
        VisibleChanged += (_, _) => { if (Visible) Reload(); }; // Registry > "Add to Exclude list" writes here too
        Reload();

        return Group("Exclude (never clean these)", list, Row(path, kind, Browse(path), add, remove), status);
    }

    void Fill(ListBox list, string prefix)
    {
        list.Items.Clear();
        list.Items.AddRange([.. settings.GetList(prefix)]);
    }

    void Append(string prefix, string entry)
    {
        settings.SetList(prefix, settings.GetList(prefix).Append(entry).Distinct(StringComparer.OrdinalIgnoreCase));
        settings.Save();
    }

    void RemoveSelected(ListBox list, string prefix)
    {
        if (list.SelectedItem is not string sel) return;
        settings.SetList(prefix, settings.GetList(prefix).Where(e => e != sel));
        settings.Save();
    }

    static ComboBox Combo(string name, string[] items, int selected, int width = 230)
    {
        var c = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = width, Name = name };
        c.Items.AddRange(items);
        c.SelectedIndex = selected;
        return c;
    }

    static Button Browse(TextBox target)
    {
        var b = new Button { Text = "Browse..." };
        b.Click += (_, _) =>
        {
            using var dlg = new FolderBrowserDialog();
            if (dlg.ShowDialog() == DialogResult.OK) target.Text = dlg.SelectedPath;
        };
        return b;
    }

    static FlowLayoutPanel Row(params Control[] controls)
    {
        var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0) };
        row.Controls.AddRange(controls);
        return row;
    }

    static GroupBox Group(string title, params Control[] controls)
    {
        var inner = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false };
        inner.Controls.AddRange(controls);
        var g = new GroupBox { Text = title, Width = 760, Height = 230, Margin = new Padding(0, 12, 0, 0) };
        g.Controls.Add(inner);
        return g;
    }
}
