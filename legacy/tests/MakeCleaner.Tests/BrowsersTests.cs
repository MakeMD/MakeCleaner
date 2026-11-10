using MakeCleaner;
using Microsoft.Data.Sqlite;

// Fake browser profiles in a temp folder; the real browsers of this machine are never touched.
public class BrowsersTests : IDisposable
{
    readonly string dir = Directory.CreateTempSubdirectory("mc-browsers-").FullName;

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        Directory.Delete(dir, true);
    }

    string Put(string rel, string content = "x")
    {
        var p = Path.Combine(dir, rel);
        Directory.CreateDirectory(Path.GetDirectoryName(p)!);
        File.WriteAllText(p, content);
        return p;
    }

    static void Db(string path, string sql)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var c = new SqliteConnection($"Data Source={path};Pooling=False");
        c.Open();
        using var cmd = c.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();
    }

    static long Count(string path, string table)
    {
        using var c = new SqliteConnection($"Data Source={path};Pooling=False");
        c.Open();
        using var cmd = c.CreateCommand();
        cmd.CommandText = $"SELECT COUNT(*) FROM {table}";
        return (long)cmd.ExecuteScalar()!;
    }

    static BrowserItem Item(List<BrowserItem> items, string id) => items.Single(i => i.Id == id);
    static List<string> Found(BrowserItem i) => [.. Engine.Analyze(i.Files).Select(f => f.FullName).Order()];

    // example.com x2, a subdomain of google.com, a look-alike and a tracker
    const string ChromeCookies = """
        CREATE TABLE cookies(host_key TEXT, name TEXT);
        INSERT INTO cookies VALUES('.example.com','a'),('www.example.com','b'),('mail.google.com','c'),('.badexample.com','d'),('tracker.net','e');
        """;

    Browser Chromium()
    {
        var ud = Path.Combine(dir, "Chrome", "User Data");
        foreach (var p in new[] { "Default", "Profile 1" })
        {
            Put($@"Chrome\User Data\{p}\Preferences", """{"savefile":{"default_directory":"C:\\Old","type":1},"homepage":"x"}""");
            Put($@"Chrome\User Data\{p}\Cache\Cache_Data\data_0");
            Put($@"Chrome\User Data\{p}\Code Cache\js\abc");
            Db(Path.Combine(ud, p, "Network", "Cookies"), ChromeCookies);
            Put($@"Chrome\User Data\{p}\Login Data");
            Put($@"Chrome\User Data\{p}\Bookmarks", "{}");
            Db(Path.Combine(ud, p, "History"), """
                CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT); INSERT INTO urls(url) VALUES('a'),('b');
                CREATE TABLE downloads(id INTEGER PRIMARY KEY); INSERT INTO downloads VALUES(1),(2),(3);
                CREATE TABLE downloads_url_chains(id INTEGER); INSERT INTO downloads_url_chains VALUES(1);
                """);
            Db(Path.Combine(ud, p, "Web Data"), """
                CREATE TABLE autofill(name TEXT); INSERT INTO autofill VALUES('email');
                CREATE TABLE keywords(id INTEGER); INSERT INTO keywords VALUES(1);
                """);
        }
        Put(@"Chrome\User Data\System Profile\Cache\x"); // no Preferences -> not a profile
        return new Browser("Fake Chrome", BrowserKind.Chromium, ud, null, "mc-no-such-process");
    }

    [Fact]
    public void Chromium_profiles_and_defaults()
    {
        var b = Chromium();
        Assert.Equal(["Default", "Profile 1"], b.Profiles().Select(Path.GetFileName).Order());

        var items = Browsers.Items(b);
        foreach (var id in new[] { "cache", "history", "downloads", "lastdownload", "cookies" })
            Assert.True(Item(items, id).Default, id);
        foreach (var id in new[] { "session", "forms", "passwords" })
        {
            Assert.False(Item(items, id).Default, id);
            Assert.NotNull(Item(items, id).Warning);
        }
        Assert.All(items, i => Assert.StartsWith("Fake Chrome: ", i.Key));
    }

    [Fact]
    public void Chromium_cache_is_files_of_every_profile()
    {
        var items = Browsers.Items(Chromium());
        var cache = Found(Item(items, "cache"));
        Assert.Equal(4, cache.Count);
        Assert.DoesNotContain(cache, f => f.Contains("System Profile"));

        var r = Engine.Clean(Engine.Analyze(Item(items, "cache").Files));
        Assert.Equal(4, r.Deleted);
        Assert.True(File.Exists(Path.Combine(dir, @"Chrome\User Data\Default\Bookmarks"))); // nothing outside the item
    }

    [Fact]
    public void Chromium_download_history_deletes_rows_not_the_history_file()
    {
        var items = Browsers.Items(Chromium());
        var downloads = Item(items, "downloads");
        Assert.Empty(downloads.Files.FileKeys);
        Assert.Equal(8, downloads.Preview()); // (3 downloads + 1 chain) x 2 profiles
        Assert.Equal(8, downloads.Run());
        var history = Path.Combine(dir, @"Chrome\User Data\Default\History");
        Assert.Equal(0, Count(history, "downloads"));
        Assert.Equal(2, Count(history, "urls"));
        Assert.Equal(0, downloads.Preview());
    }

    [Fact]
    public void Chromium_forms_clear_autofill_but_keep_search_engines()
    {
        var forms = Item(Browsers.Items(Chromium()), "forms");
        Assert.Equal(2, forms.Run());
        var webData = Path.Combine(dir, @"Chrome\User Data\Profile 1\Web Data");
        Assert.Equal(0, Count(webData, "autofill"));
        Assert.Equal(1, Count(webData, "keywords"));
    }

    [Fact]
    public void Chromium_last_download_location_drops_only_that_key()
    {
        var last = Item(Browsers.Items(Chromium()), "lastdownload");
        Assert.Equal(2, last.Preview());
        Assert.Equal(2, last.Run());
        var prefs = File.ReadAllText(Path.Combine(dir, @"Chrome\User Data\Default\Preferences"));
        Assert.DoesNotContain("default_directory", prefs);
        Assert.Contains("homepage", prefs);
        Assert.Contains("\"type\":1", prefs);
        Assert.Equal(0, last.Preview());
    }

    [Fact]
    public void Opera_profile_in_root_with_cache_on_the_local_side()
    {
        Put(@"Roaming\Opera Stable\Preferences", "{}");
        Db(Path.Combine(dir, @"Roaming\Opera Stable\Network\Cookies"), ChromeCookies);
        Put(@"Local\Opera Stable\Cache\Cache_Data\f_000001");
        var b = new Browser("Fake Opera", BrowserKind.Chromium, Path.Combine(dir, @"Roaming\Opera Stable"), Path.Combine(dir, @"Local\Opera Stable"), "mc-no-such-process");

        var items = Browsers.Items(b);
        Assert.Single(b.Profiles());
        Assert.Equal([Path.Combine(dir, @"Local\Opera Stable\Cache\Cache_Data\f_000001")], Found(Item(items, "cache")));
        Assert.Equal(5, Item(items, "cookies").Preview());
    }

    Browser Firefox()
    {
        var roaming = Path.Combine(dir, @"Roaming\Firefox");
        var abs = Path.Combine(dir, "ElsewhereProfile");
        Put(@"Roaming\Firefox\profiles.ini", $"""
            [General]
            StartWithLastProfile=1

            [Profile0]
            Name=default-release
            IsRelative=1
            Path=Profiles/abc.default-release

            [Profile1]
            Name=other
            IsRelative=0
            Path={abs}

            [Install123]
            Default=Profiles/abc.default-release
            """);
        foreach (var p in new[] { Path.Combine(roaming, @"Profiles\abc.default-release"), abs })
        {
            Db(Path.Combine(p, "places.sqlite"), """
                CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT); INSERT INTO moz_places VALUES(1,'bookmarked'),(2,'visited');
                CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY, fk INTEGER); INSERT INTO moz_bookmarks VALUES(1,1),(2,NULL);
                CREATE TABLE moz_historyvisits(id INTEGER PRIMARY KEY, place_id INTEGER); INSERT INTO moz_historyvisits VALUES(1,1),(2,2);
                CREATE TABLE moz_inputhistory(place_id INTEGER); INSERT INTO moz_inputhistory VALUES(2);
                CREATE TABLE moz_anno_attributes(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO moz_anno_attributes VALUES(1,'downloads/destinationFileURI'),(2,'other');
                CREATE TABLE moz_annos(id INTEGER PRIMARY KEY, anno_attribute_id INTEGER); INSERT INTO moz_annos VALUES(1,1),(2,2);
                """);
            Db(Path.Combine(p, "cookies.sqlite"), """
                CREATE TABLE moz_cookies(id INTEGER PRIMARY KEY, host TEXT); INSERT INTO moz_cookies(host) VALUES('.example.com'),('accounts.google.com'),('tracker.net');
                """);
            File.WriteAllText(Path.Combine(p, "logins.json"), "{}");
            File.WriteAllText(Path.Combine(p, "prefs.js"), "user_pref(\"browser.download.lastDir\", \"C:\\\\Old\");\nuser_pref(\"browser.startup.page\", 3);\n");
            Directory.CreateDirectory(Path.Combine(p, "sessionstore-backups"));
            File.WriteAllText(Path.Combine(p, @"sessionstore-backups\recovery.jsonlz4"), "x");
        }
        Put(@"Local\Firefox\Profiles\abc.default-release\cache2\entries\E1");
        return new Browser("Fake Firefox", BrowserKind.Firefox, roaming, Path.Combine(dir, @"Local\Firefox"), "mc-no-such-process");
    }

    [Fact]
    public void Firefox_profiles_come_from_profiles_ini_relative_and_absolute()
    {
        var b = Firefox();
        Assert.Equal(["ElsewhereProfile", "abc.default-release"], b.Profiles().Select(Path.GetFileName).Order(StringComparer.Ordinal));
        var items = Browsers.Items(b);
        Assert.Equal([Path.Combine(dir, @"Local\Firefox\Profiles\abc.default-release\cache2\entries\E1")], Found(Item(items, "cache")));
        Assert.Equal(2, Browsers.CookieDbs(b).Count());
        Assert.Equal(2, Found(Item(items, "session")).Count);
        Assert.Equal(2, Found(Item(items, "passwords")).Count);
    }

    [Fact]
    public void Firefox_history_keeps_bookmarks()
    {
        var items = Browsers.Items(Firefox());
        var history = Item(items, "history");
        Assert.Equal(4, history.Preview()); // 2 visits x 2 profiles
        history.Run();
        var places = Path.Combine(dir, @"Roaming\Firefox\Profiles\abc.default-release\places.sqlite");
        Assert.Equal(0, Count(places, "moz_historyvisits"));
        Assert.Equal(0, Count(places, "moz_inputhistory"));
        Assert.Equal(1, Count(places, "moz_places")); // the bookmarked one stays
        Assert.Equal(2, Count(places, "moz_bookmarks"));

        var downloads = Item(items, "downloads");
        Assert.Equal(2, downloads.Run());
        Assert.Equal(1, Count(places, "moz_annos"));
    }

    [Fact]
    public void Firefox_last_download_location_removes_only_that_pref()
    {
        var last = Item(Browsers.Items(Firefox()), "lastdownload");
        Assert.Equal(2, last.Run());
        var prefs = File.ReadAllText(Path.Combine(dir, "ElsewhereProfile", "prefs.js"));
        Assert.DoesNotContain("lastDir", prefs);
        Assert.Contains("browser.startup.page", prefs);
    }

    static long Rows(string db, string table) { SqliteConnection.ClearAllPools(); return Count(db, table); }

    [Fact]
    public void Cookies_are_rows_and_keep_list_domains_survive_in_chromium_and_firefox()
    {
        var chrome = Browsers.Items(Chromium());
        var firefox = Browsers.Items(Firefox());
        var chromeDb = Path.Combine(dir, @"Chrome\User Data\Default\Network\Cookies");
        var firefoxDb = Path.Combine(dir, "ElsewhereProfile", "cookies.sqlite");
        try
        {
            Assert.Empty(Item(chrome, "cookies").Files.FileKeys); // the database file itself is never deleted
            Assert.Equal(10, Item(chrome, "cookies").Preview());  // empty keep-list: every cookie, 5 x 2 profiles

            Cookies.Keep = () => ["www.example.com", "google.com"];
            Assert.Equal(4, Item(chrome, "cookies").Preview());   // badexample.com + tracker.net, x 2
            Assert.Equal(5, Rows(chromeDb, "cookies"));            // preview changed nothing
            Assert.Equal(4, Item(chrome, "cookies").Run());
            Assert.Equal(2, Item(firefox, "cookies").Run());      // tracker.net x 2 profiles

            SqliteConnection.ClearAllPools();
            using var c = new SqliteConnection($"Data Source={chromeDb};Pooling=False");
            c.Open();
            using var cmd = c.CreateCommand();
            cmd.CommandText = "SELECT host_key FROM cookies ORDER BY host_key";
            var left = new List<string>();
            using (var r = cmd.ExecuteReader())
                while (r.Read()) left.Add(r.GetString(0));
            Assert.Equal([".example.com", "mail.google.com", "www.example.com"], left);
            Assert.Equal(2, Rows(firefoxDb, "moz_cookies"));
        }
        finally { Cookies.Keep = () => []; }
    }

    [Fact]
    public void Cookie_domains_are_listed_normalized_even_from_a_locked_database()
    {
        var b = Chromium();
        var f = Firefox();
        var db = Path.Combine(dir, @"Chrome\User Data\Default\Network\Cookies");
        var before = Directory.GetDirectories(Path.GetTempPath(), "mc-cookies-*").Length;
        // what a running browser does: hold an exclusive lock so other connections cannot read
        using (var hold = new SqliteConnection($"Data Source={db};Pooling=False"))
        {
            hold.Open();
            using (var cmd = hold.CreateCommand()) { cmd.CommandText = "PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE;"; cmd.ExecuteNonQuery(); }

            var sw = System.Diagnostics.Stopwatch.StartNew();
            var domains = Browsers.CookieDomains([b, f]);
            Assert.Equal(["accounts.google.com", "badexample.com", "example.com", "mail.google.com", "tracker.net"], domains);
            Assert.True(sw.ElapsedMilliseconds < 10000, $"locked db took {sw.ElapsedMilliseconds} ms");
        }
        Assert.Equal(before, Directory.GetDirectories(Path.GetTempPath(), "mc-cookies-*").Length); // temp copies cleaned up
    }

    [Fact]
    public void Compact_vacuums_databases()
    {
        var compact = Item(Browsers.Items(Firefox()), "compact");
        Assert.Equal(4, compact.Preview()); // places.sqlite + cookies.sqlite, x 2 profiles
        compact.Run();
    }

    [Fact]
    public void Missing_browser_shows_nothing_and_is_not_running()
    {
        var b = new Browser("Nope", BrowserKind.Chromium, Path.Combine(dir, "nothing"), null, "mc-no-such-process");
        Assert.Empty(Browsers.Detect([b]));
        Assert.Empty(b.Running());
        Assert.True(Browsers.CloseGracefully([]));
        Assert.NotEmpty(Browsers.Detect([Chromium()]));
    }

    [Fact]
    public void Replaced_winapp2_sections_exist_in_the_bundled_file()
    {
        var sections = Rule.ParseIni(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "rules", "Winapp2.ini")))
            .Select(r => r.Section).ToHashSet(StringComparer.OrdinalIgnoreCase);
        Assert.All(Browsers.ReplacedWinapp2Sections, s => Assert.Contains(s, sections));
    }
}
