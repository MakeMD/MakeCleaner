using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace MakeCleaner;

// Options: Settings, Include, Exclude, Cookies, Schedule, About. Settings keys are the ones v1.0 (WinForms) used,
// so an upgrade keeps every list; saved immediately on change. AutomationIds are what tools/*smoke*.ps1 look up.
public static class OptionsPages
{
    static readonly string[] IncludeModes = ["Files only", "Files and subfolders", "Files, subfolders and the folder itself"];
    static readonly string[] ExcludeKinds = ["Folder", "File", "Registry key"];

    public static SubNavPage Build(Settings s) => new SubNavPage("Options")
        .Add("Settings", () => Scroll(SettingsPage(s)))
        .Add("Include", () => Scroll(IncludePage(s)))
        .Add("Exclude", () => Scroll(ExcludePage(s)))
        .Add("Cookies", () => Scroll(CookiesPage(s)))
        .Add("Schedule", () => Scroll(SchedulePage()))
        .Add("About", () => Scroll(Page("About", Text(AboutText, wrap: true))));

    static ScrollViewer Scroll(UIElement page) => new() { Content = page, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };

    // The one About text: footer dialog and the About page.
    public static string AboutText =>
        $"MakeCleaner {FileVersionInfo.GetVersionInfo(Environment.ProcessPath!).ProductVersion}\n\n" +
        "No telemetry, no ads, no network access.\n\n" +
        "Applications rules: Winapp2.ini by the Winapp2 project (github.com/MoscaDotTo/Winapp2), " +
        "licensed CC BY-SA 4.0, shipped unmodified in rules\\Winapp2.ini.\n\n" +
        "Third-party components: see THIRD-PARTY-NOTICES.txt next to the program.";

    static UIElement SettingsPage(Settings s)
    {
        var method = Combo("secureDelete", [.. SecureDelete.Methods.Select(m => m.Label)],
            Math.Max(0, Array.FindIndex(SecureDelete.Methods, m => m.Passes == s.GetInt(SecureDelete.SettingKey, 0))), 320);
        method.SelectionChanged += (_, _) => { s.Set(SecureDelete.SettingKey, SecureDelete.Methods[method.SelectedIndex].Passes); s.Save(); };
        var page = Page("Settings", Text("Secure deletion (applies to every clean)"), method);
        // Keys match AgeOption= in rules\Windows.ini.
        foreach (var (key, text) in new[] { ("TempOlderThan24h", "Only delete files in Windows Temp folders older than 24 hours"),
                                            ("RecycleBinOlderThan24h", "Only delete Recycle Bin items deleted more than 24 hours ago") })
        {
            var box = new CheckBox { Content = text, IsChecked = s.GetBool(key, false), Margin = new Thickness(0, 12, 0, 0) };
            AutomationProperties.SetAutomationId(box, key);
            box.Click += (_, _) => { s.Set(key, box.IsChecked == true); s.Save(); };
            Add(page, box);
        }
        return page;
    }

    static UIElement IncludePage(Settings s)
    {
        var list = List("incList");
        var path = Box("incPath", 300);
        var mode = Combo("incMode", IncludeModes, 1);
        var pattern = Box("incPattern", 100, "*.*");
        var age = Box("incAge", 60, "0");
        var status = Status("incStatus");
        void Reload() => Fill(list, s, Custom.IncludePrefix);

        var add = Btn("Add", "incAdd", () =>
        {
            var p = path.Text.Trim();
            if (Custom.Reject(p) is { } why) { status.Text = why; return; }
            if (!int.TryParse(age.Text.Trim(), out var hours) || hours < 0) { status.Text = "Hours must be a whole number, 0 = any age."; return; }
            var full = Path.GetFullPath(Environment.ExpandEnvironmentVariables(p));
            string entry;
            if (File.Exists(full)) entry = $"{Path.GetDirectoryName(full)}|{Path.GetFileName(full)}";
            else if (Directory.Exists(full))
                entry = $"{full}|{(pattern.Text.Trim().Length > 0 ? pattern.Text.Trim() : "*.*")}"
                        + mode.SelectedIndex switch { 1 => "|RECURSE", 2 => "|REMOVESELF", _ => "" };
            else { status.Text = "Folder or file not found."; return; }
            if (hours > 0) entry += $"|OLDER={hours}";
            s.SetList(Custom.IncludePrefix, s.GetList(Custom.IncludePrefix).Append(entry).Distinct(StringComparer.OrdinalIgnoreCase));
            s.Save();
            Reload();
            path.Clear();
            status.Text = $"Added. Tick \"{Custom.RuleName}\" in Cleaner > Windows to clean it.";
        });
        var remove = Btn("Remove", "incRemove", () => { RemoveSelected(list, s, Custom.IncludePrefix); Reload(); });
        Reload();
        return Page("Include", Text("Extra files and folders to clean. Folder or file, e.g. D:\\Logs."),
            Row(path, Browse(path), add, remove),
            Row(Text("Mode:"), mode, Text("Mask:"), pattern, Text("Hours old (0 = any):"), age),
            list, status);
    }

    static UIElement ExcludePage(Settings s)
    {
        var list = List("excList");
        var path = Box("excPath", 170);
        var kind = Combo("excKind", ExcludeKinds, 0, 130);
        var status = Status("excStatus");
        void Reload() => Fill(list, s, Custom.ExcludePrefix);

        var add = Btn("Add", "excAdd", () =>
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
            Custom.AddExclude(s, entry);
            Reload();
            path.Clear();
            status.Text = "Added. Excluded items are skipped by every cleaner.";
        });
        var remove = Btn("Remove", "excRemove", () => { RemoveSelected(list, s, Custom.ExcludePrefix); Reload(); });
        var page = Page("Exclude", Text(@"Never clean these. Folder, file or registry key (HKCU\Software\Key[|Value])."),
            Row(path, kind, Browse(path), add, remove), list, status);
        page.IsVisibleChanged += (_, e) => { if ((bool)e.NewValue) Reload(); }; // Cleaner / Registry "Add to Exclude" write here too
        Reload();
        return page;
    }

    // Left: every cookie domain the browsers hold; right: the keep-list. Kept domains survive every Cookies clean.
    static UIElement CookiesPage(Settings s)
    {
        var all = List("cookieAll", 250, 220, multi: true);
        var keep = List("cookieKeep", 250, 220, multi: true);
        var domain = Box("cookieDomain", 200);
        var status = Status("cookieStatus");
        List<string> found = [];
        List<string> Kept() => s.GetList(Cookies.KeepPrefix);
        void Show()
        {
            var kept = Kept();
            keep.ItemsSource = kept;
            all.ItemsSource = found.Where(d => !Cookies.IsKept(d, kept)).Order(StringComparer.OrdinalIgnoreCase).ToList();
        }
        void Save(IEnumerable<string> domains)
        {
            s.SetList(Cookies.KeepPrefix, Cookies.Parse(domains));
            s.Save();
            Show();
        }
        Button scan = null!;
        async Task Scan()
        {
            scan.IsEnabled = false;
            status.Text = "Reading cookies from browsers...";
            found = await Task.Run(() => Browsers.CookieDomains());
            Show();
            status.Text = $"{found.Count} domains with cookies, {Kept().Count} kept";
            scan.IsEnabled = true;
        }
        scan = Btn("Rescan", "cookieScan", async () => await Scan());
        var toKeep = Btn("Keep >", "cookieToKeep", () => Save([.. Kept(), .. all.SelectedItems.Cast<string>()]));
        var toAll = Btn("< Remove", "cookieRemove", () =>
        {
            var drop = keep.SelectedItems.Cast<string>().ToHashSet();
            Save(Kept().Where(d => !drop.Contains(d)));
        });
        var add = Btn("Add", "cookieAdd", () =>
        {
            if (Cookies.Parse([domain.Text]) is not [var d] || !d.Contains('.')) { status.Text = "Enter a domain like example.com."; return; }
            Save([.. Kept(), d]);
            domain.Clear();
            status.Text = $"Keeping cookies of {d} and its subdomains.";
        });
        var import = Btn("Import...", "cookieImport", () =>
        {
            var dlg = new Microsoft.Win32.OpenFileDialog { Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*" };
            if (dlg.ShowDialog() != true) return;
            var added = Cookies.Parse(File.ReadLines(dlg.FileName));
            Save([.. Kept(), .. added]);
            status.Text = $"Imported {added.Count} domains.";
        });
        var export = Btn("Export...", "cookieExport", () =>
        {
            var dlg = new Microsoft.Win32.SaveFileDialog { Filter = "Text files (*.txt)|*.txt", FileName = "cookies-to-keep.txt" };
            if (dlg.ShowDialog() != true) return;
            File.WriteAllLines(dlg.FileName, Kept());
            status.Text = $"Exported {Kept().Count} domains.";
        });
        var arrows = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 10, 0) };
        arrows.Children.Add(toKeep);
        toAll.Margin = new Thickness(0, 8, 0, 0);
        arrows.Children.Add(toAll);
        var lists = Row(Column(Text("Cookies on computer"), all), arrows, Column(Text("Cookies to keep"), keep));
        var page = Page("Cookies", Text("Domains to keep when browser cookies are cleaned (subdomains included)."),
            lists, Row(domain, add, scan, import, export), status);
        page.Loaded += async (_, _) => { if (found.Count == 0 && scan.IsEnabled) await Scan(); };
        Show();
        return page;
    }

    // The only way MakeCleaner runs by itself: a task the user creates here and removes here.
    static UIElement SchedulePage()
    {
        var kind = Combo("schedKind", ["Once", "Daily", "Weekly (same weekday)", "At sign-in"], 1, 190);
        var at = Box("schedAt", 150, DateTime.Today.AddDays(1).AddHours(12).ToString("yyyy-MM-dd HH:mm"));
        var shutdown = new CheckBox { Content = "Shut down the PC afterwards", VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAutomationId(shutdown, "schedShutdown");
        var status = Status("schedStatus");
        void Show() => status.Text = Schedule.Describe() ?? "No scheduled cleaning.";
        kind.SelectionChanged += (_, _) => at.IsEnabled = kind.SelectedIndex != (int)ScheduleKind.AtLogon;
        var create = Btn("Create task", "schedCreate", () =>
        {
            if (!DateTime.TryParseExact(at.Text.Trim(), "yyyy-MM-dd HH:mm", null, System.Globalization.DateTimeStyles.None, out var when))
            { status.Text = "Start time format: yyyy-MM-dd HH:mm"; return; }
            try { Schedule.Create((ScheduleKind)kind.SelectedIndex, when, shutdown.IsChecked == true); Show(); }
            catch (Exception e) when (e is System.Runtime.InteropServices.COMException or UnauthorizedAccessException) { status.Text = "Could not create the task: " + e.Message; }
        });
        var remove = Btn("Remove task", "schedRemove", () => { Schedule.Delete(); Show(); });
        Show();
        return Page("Schedule", Text("Runs MakeCleaner /auto with the items ticked in Cleaner. Wipe Free Space is never run.", wrap: true),
            Row(kind, Text("Start:"), at, shutdown), Row(create, remove), status);
    }

    // ---- small builders (this file only) ----

    static Brush Res(string key) => (Brush)Application.Current.FindResource(key);

    static StackPanel Page(string title, params UIElement[] items)
    {
        var p = new StackPanel();
        p.Children.Add(new TextBlock { Text = title, FontSize = 18, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 10) });
        foreach (var i in items) Add(p, i);
        return p;
    }

    static void Add(StackPanel p, UIElement e)
    {
        if (e is FrameworkElement f)
        {
            if (f.Margin == default) f.Margin = new Thickness(0, 8, 0, 0);
            f.HorizontalAlignment = HorizontalAlignment.Left; // fixed-width controls hug the left edge, not the centre
        }
        p.Children.Add(e);
    }

    static TextBlock Text(string text, bool wrap = false) => new()
    {
        Text = text, VerticalAlignment = VerticalAlignment.Center, Foreground = Res("Muted"),
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap, MaxWidth = wrap ? 640 : double.PositiveInfinity,
    };

    static TextBlock Status(string id)
    {
        var t = new TextBlock { TextWrapping = TextWrapping.Wrap, MaxWidth = 640, FontWeight = FontWeights.SemiBold };
        AutomationProperties.SetAutomationId(t, id);
        return t;
    }

    static TextBox Box(string id, double width, string text = "")
    {
        var b = new TextBox { Width = width, Text = text, Padding = new Thickness(4, 5, 4, 5), VerticalContentAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAutomationId(b, id);
        return b;
    }

    static ComboBox Combo(string id, string[] items, int selected, double width = 230)
    {
        var c = new ComboBox { Width = width, ItemsSource = items, SelectedIndex = selected, VerticalContentAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAutomationId(c, id);
        return c;
    }

    static ListBox List(string id, double width = 640, double height = 160, bool multi = false)
    {
        var l = new ListBox { Width = width, Height = height, HorizontalAlignment = HorizontalAlignment.Left, BorderBrush = Res("Line"),
                              SelectionMode = multi ? SelectionMode.Extended : SelectionMode.Single };
        VirtualizingPanel.SetIsVirtualizing(l, false); // short lists; realised items keep UI Automation able to see them all
        AutomationProperties.SetAutomationId(l, id);
        return l;
    }

    static Button Btn(string text, string id, Action click)
    {
        var b = new Button { Content = text, MinWidth = 90 };
        AutomationProperties.SetAutomationId(b, id);
        b.Click += (_, _) => click();
        return b;
    }

    static Button Browse(TextBox target) => Btn("Browse...", AutomationProperties.GetAutomationId(target) + "Browse", () =>
    {
        var dlg = new Microsoft.Win32.OpenFolderDialog();
        if (dlg.ShowDialog() == true) target.Text = dlg.FolderName;
    });

    // wraps instead of clipping when the window is narrow
    static WrapPanel Row(params UIElement[] items)
    {
        var r = new WrapPanel();
        foreach (var i in items)
        {
            if (i is FrameworkElement f) f.Margin = new Thickness(0, 0, 8, 6);
            r.Children.Add(i);
        }
        return r;
    }

    static StackPanel Column(params UIElement[] items)
    {
        var c = new StackPanel();
        foreach (var i in items) c.Children.Add(i);
        return c;
    }

    static void Fill(ListBox list, Settings s, string prefix) => list.ItemsSource = s.GetList(prefix);

    static void RemoveSelected(ListBox list, Settings s, string prefix)
    {
        if (list.SelectedItem is not string sel) return;
        s.SetList(prefix, s.GetList(prefix).Where(e => e != sel));
        s.Save();
    }
}
