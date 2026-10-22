namespace MakeCleaner;

// Options section. Saved immediately on change.
public class OptionsPanel : UserControl
{
    static readonly string[] IncludeModes = ["Files only", "Files and subfolders", "Files, subfolders and the folder itself"];
    static readonly string[] ExcludeKinds = ["Folder", "File", "Registry key"];

    readonly Settings settings;

    public OptionsPanel(Settings settings)
    {
        this.settings = settings;
        var method = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 320, Name = "secureDelete" };
        foreach (var m in SecureDelete.Methods) method.Items.Add(m.Label);
        var current = settings.GetInt(SecureDelete.SettingKey, 0);
        method.SelectedIndex = Math.Max(0, Array.FindIndex(SecureDelete.Methods, m => m.Passes == current));
        method.SelectedIndexChanged += (_, _) =>
        {
            settings.Set(SecureDelete.SettingKey, SecureDelete.Methods[method.SelectedIndex].Passes);
            settings.Save();
        };

        var layout = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, Padding = new Padding(12), AutoScroll = true, WrapContents = false };
        layout.Controls.Add(new Label { Text = "Secure Deletion (applies to every clean)", AutoSize = true });
        layout.Controls.Add(method);
        // Keys match AgeOption= in rules\Windows.ini.
        foreach (var (key, text) in new[] { ("TempOlderThan24h", "Only delete files in Windows Temp folders older than 24 hours"),
                                            ("RecycleBinOlderThan24h", "Only delete Recycle Bin items deleted more than 24 hours ago") })
        {
            var box = new CheckBox { Text = text, AutoSize = true, Checked = settings.GetBool(key, false), Name = key, Margin = new Padding(0, 8, 0, 0) };
            box.CheckedChanged += (_, _) => { settings.Set(key, box.Checked); settings.Save(); };
            layout.Controls.Add(box);
        }
        layout.Controls.Add(IncludeGroup());
        layout.Controls.Add(ExcludeGroup());
        layout.Controls.Add(CookiesGroup());
        layout.Controls.Add(ScheduleGroup());
        Controls.Add(layout);
    }

    // The only way MakeCleaner runs by itself: a task the user creates here and removes here.
    static GroupBox ScheduleGroup()
    {
        var kind = Combo("schedKind", ["Once", "Daily", "Weekly (same weekday)", "At sign-in"], 1, 170);
        var at = new DateTimePicker { Format = DateTimePickerFormat.Custom, CustomFormat = "yyyy-MM-dd HH:mm", ShowUpDown = true, Width = 150, Name = "schedAt",
                                      Value = DateTime.Today.AddDays(1).AddHours(12) };
        var shutdown = new CheckBox { Text = "Shut down the PC afterwards", AutoSize = true, Name = "schedShutdown" };
        var create = new Button { Text = "Create task", AutoSize = true, Name = "schedCreate" };
        var remove = new Button { Text = "Remove task", AutoSize = true, Name = "schedRemove" };
        var status = new Label { AutoSize = true, Name = "schedStatus" };
        void Show() => status.Text = Schedule.Describe() ?? "No scheduled cleaning.";
        kind.SelectedIndexChanged += (_, _) => at.Enabled = kind.SelectedIndex != (int)ScheduleKind.AtLogon;
        create.Click += (_, _) =>
        {
            try { Schedule.Create((ScheduleKind)kind.SelectedIndex, at.Value, shutdown.Checked); Show(); }
            catch (Exception e) when (e is System.Runtime.InteropServices.COMException or UnauthorizedAccessException) { status.Text = "Could not create the task: " + e.Message; }
        };
        remove.Click += (_, _) => { Schedule.Delete(); Show(); };
        Show();
        return Group("Scheduled cleaning (runs MakeCleaner /auto with the items ticked in Cleaner; Wipe Free Space is never run)",
            Row(kind, at, shutdown), Row(create, remove), status);
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

    // Left: every cookie domain the browsers hold; right: the keep-list. Kept domains survive every Cookies clean.
    GroupBox CookiesGroup()
    {
        var all = new ListBox { Width = 300, Height = 150, Name = "cookieAll", SelectionMode = SelectionMode.MultiExtended, Sorted = true };
        var keep = new ListBox { Width = 300, Height = 150, Name = "cookieKeep", SelectionMode = SelectionMode.MultiExtended };
        var toKeep = new Button { Text = "Keep >", Name = "cookieToKeep" };
        var toAll = new Button { Text = "< Remove", Name = "cookieRemove" };
        var domain = new TextBox { Width = 300, Name = "cookieDomain", PlaceholderText = "example.com" };
        var add = new Button { Text = "Add", Name = "cookieAdd" };
        var scan = new Button { Text = "Rescan", Name = "cookieScan" };
        var import = new Button { Text = "Import...", Name = "cookieImport" };
        var export = new Button { Text = "Export...", Name = "cookieExport" };
        var status = new Label { AutoSize = true, Name = "cookieStatus" };
        List<string> found = [];

        List<string> Kept() => settings.GetList(Cookies.KeepPrefix);
        void Show()
        {
            var kept = Kept();
            keep.Items.Clear();
            keep.Items.AddRange([.. kept]);
            all.Items.Clear();
            all.Items.AddRange([.. found.Where(d => !Cookies.IsKept(d, kept))]);
        }
        void Save(IEnumerable<string> domains)
        {
            settings.SetList(Cookies.KeepPrefix, Cookies.Parse(domains));
            settings.Save();
            Show();
        }
        async Task Scan()
        {
            scan.Enabled = false;
            status.Text = "Reading cookies from browsers...";
            found = await Task.Run(() => Browsers.CookieDomains());
            Show();
            status.Text = $"{found.Count} domains with cookies, {Kept().Count} kept";
            scan.Enabled = true;
        }

        toKeep.Click += (_, _) => Save([.. Kept(), .. all.SelectedItems.Cast<string>()]);
        toAll.Click += (_, _) =>
        {
            var drop = keep.SelectedItems.Cast<string>().ToHashSet();
            Save(Kept().Where(d => !drop.Contains(d)));
        };
        add.Click += (_, _) =>
        {
            if (Cookies.Parse([domain.Text]) is not [var d] || !d.Contains('.')) { status.Text = "Enter a domain like example.com."; return; }
            Save([.. Kept(), d]);
            domain.Clear();
            status.Text = $"Keeping cookies of {d} and its subdomains.";
        };
        scan.Click += async (_, _) => await Scan();
        import.Click += (_, _) =>
        {
            using var dlg = new OpenFileDialog { Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*" };
            if (dlg.ShowDialog() != DialogResult.OK) return;
            var added = Cookies.Parse(File.ReadLines(dlg.FileName));
            Save([.. Kept(), .. added]);
            status.Text = $"Imported {added.Count} domains.";
        };
        export.Click += (_, _) =>
        {
            using var dlg = new SaveFileDialog { Filter = "Text files (*.txt)|*.txt", FileName = "cookies-to-keep.txt" };
            if (dlg.ShowDialog() != DialogResult.OK) return;
            File.WriteAllLines(dlg.FileName, Kept());
            status.Text = $"Exported {Kept().Count} domains.";
        };
        var scanned = false;
        VisibleChanged += async (_, _) => { if (Visible && !scanned) { scanned = true; await Scan(); } };
        Show();

        static FlowLayoutPanel Column(params Control[] c)
        {
            var col = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Margin = new Padding(0) };
            col.Controls.AddRange(c);
            return col;
        }
        var g = Group("Cookies (domains to keep when cleaning browser cookies)",
            Row(Column(new Label { Text = "Cookies on computer", AutoSize = true }, all),
                Column(new Label { Text = " ", AutoSize = true }, toKeep, toAll),
                Column(new Label { Text = "Cookies to keep", AutoSize = true }, keep)),
            Row(domain, add, scan, import, export),
            status);
        g.Height = 290;
        return g;
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
