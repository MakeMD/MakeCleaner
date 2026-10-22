using System.Diagnostics;
using System.Text.Json.Nodes;
using Microsoft.Data.Sqlite;

namespace MakeCleaner;

public enum BrowserKind { Chromium, Firefox }

// Root = Chromium "User Data" (or the profile itself, Opera) / Firefox folder holding profiles.ini.
// LocalRoot = where the cache lives when it is split from the roaming profile (Opera, Firefox).
public record Browser(string Name, BrowserKind Kind, string Root, string? LocalRoot, string Process)
{
    // Root wildcards (Arc's package folder) go through the same expansion as rules.
    public IEnumerable<string> Roots() => Paths.ExpandDirs(Root);

    public IEnumerable<string> Profiles() => Kind == BrowserKind.Firefox ? Browsers.FirefoxProfiles(this) : Browsers.ChromiumProfiles(this);

    // Same profile on the local side: Root\X -> LocalRoot\X.
    public string? LocalOf(string profile)
    {
        if (LocalRoot == null) return null;
        foreach (var root in Roots())
            if (profile.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                foreach (var local in Paths.ExpandDirs(LocalRoot).DefaultIfEmpty(Environment.ExpandEnvironmentVariables(LocalRoot)))
                    return Path.Join(local, profile[root.Length..]);
        return null;
    }

    public List<Process> Running() => [.. System.Diagnostics.Process.GetProcessesByName(Process)];
}

// One checkbox. Files go through Engine (excludes, secure delete); Action covers what is not a file
// (SQL rows, a JSON/prefs value). Id is stable so ticket 06 can swap the "cookies" item for row deletion.
public record BrowserItem(string Browser, string Id, string Name, bool Default, string? Warning, Rule Files, Func<bool, int>? Action = null)
{
    public string Key => $"{Browser}: {Name}";
    public int Preview() => Action?.Invoke(false) ?? 0; // rows/values that would go
    public int Run() => Action?.Invoke(true) ?? 0;
}

public static class Browsers
{
    public static readonly Browser[] Known =
    [
        new("Google Chrome", BrowserKind.Chromium, @"%LocalAppData%\Google\Chrome\User Data", null, "chrome"),
        new("Microsoft Edge", BrowserKind.Chromium, @"%LocalAppData%\Microsoft\Edge\User Data", null, "msedge"),
        new("Brave", BrowserKind.Chromium, @"%LocalAppData%\BraveSoftware\Brave-Browser\User Data", null, "brave"),
        new("Vivaldi", BrowserKind.Chromium, @"%LocalAppData%\Vivaldi\User Data", null, "vivaldi"),
        // ponytail: Opera and Opera GX share opera.exe, so "close Opera" closes both; split by exe path if it matters
        new("Opera", BrowserKind.Chromium, @"%AppData%\Opera Software\Opera Stable", @"%LocalAppData%\Opera Software\Opera Stable", "opera"),
        new("Opera GX", BrowserKind.Chromium, @"%AppData%\Opera Software\Opera GX Stable", @"%LocalAppData%\Opera Software\Opera GX Stable", "opera"),
        new("Arc", BrowserKind.Chromium, @"%LocalAppData%\Packages\TheBrowserCompany.Arc_*\LocalCache\Local\Arc\User Data", null, "Arc"),
        new("Mozilla Firefox", BrowserKind.Firefox, @"%AppData%\Mozilla\Firefox", @"%LocalAppData%\Mozilla\Firefox", "firefox"),
    ];

    // Winapp2 sections replaced by this tab (no double entries); other browsers stay with Winapp2.
    public static readonly HashSet<string> ReplacedWinapp2Sections = new(StringComparer.OrdinalIgnoreCase)
    {
        "Google Chrome Web Browser", "Microsoft Edge Web Browser", "Brave Web Browser", "Vivaldi Web Browser",
        "Opera Web Browser", "Opera GX Web Browser", "Arc Web Browser", "Mozilla Firefox Web Browser",
    };

    // Asks every window to close (like clicking X) and waits; never kills. False if something is still running.
    public static bool CloseGracefully(List<Process> running, int timeoutMs = 10000)
    {
        foreach (var p in running) try { p.CloseMainWindow(); } catch (InvalidOperationException) { }
        var deadline = Environment.TickCount64 + timeoutMs;
        foreach (var p in running)
            try { if (!p.WaitForExit((int)Math.Max(0, deadline - Environment.TickCount64))) return false; }
            catch (InvalidOperationException) { }
        return true;
    }

    public static List<BrowserItem> Detect(IEnumerable<Browser>? browsers = null) =>
        [.. (browsers ?? Known).SelectMany(b => b.Profiles().Any() ? Items(b) : [])];

    // Default, Profile N, Guest Profile; Opera keeps the profile in the root itself.
    public static IEnumerable<string> ChromiumProfiles(Browser b)
    {
        foreach (var root in b.Roots())
        {
            if (File.Exists(Path.Join(root, "Preferences"))) yield return root;
            foreach (var d in SafeDirs(root))
            {
                var name = Path.GetFileName(d);
                if ((name == "Default" || name.StartsWith("Profile ") || name == "Guest Profile") && File.Exists(Path.Join(d, "Preferences")))
                    yield return d;
            }
        }
    }

    // Every [Profile*] in profiles.ini; IsRelative=1 paths are under the root.
    public static IEnumerable<string> FirefoxProfiles(Browser b)
    {
        foreach (var root in b.Roots())
        {
            var ini = Path.Join(root, "profiles.ini");
            if (!File.Exists(ini)) continue;
            string? path = null;
            var relative = true;
            var inProfile = false;
            foreach (var raw in File.ReadAllLines(ini).Append("[end]"))
            {
                var line = raw.Trim();
                if (line.StartsWith('['))
                {
                    if (inProfile && path != null)
                    {
                        var full = relative ? Path.GetFullPath(Path.Join(root, path.Replace('/', '\\'))) : path;
                        if (Directory.Exists(full)) yield return full;
                    }
                    inProfile = line.StartsWith("[Profile", StringComparison.OrdinalIgnoreCase);
                    (path, relative) = (null, true);
                    continue;
                }
                var eq = line.IndexOf('=');
                if (!inProfile || eq < 0) continue;
                var (k, v) = (line[..eq].Trim(), line[(eq + 1)..].Trim());
                if (k.Equals("Path", StringComparison.OrdinalIgnoreCase)) path = v;
                else if (k.Equals("IsRelative", StringComparison.OrdinalIgnoreCase)) relative = v != "0";
            }
        }
    }

    const string LoseLogins = "This deletes saved passwords. You will have to sign in again on every site.";
    const string LoseForms = "This deletes saved form entries and autofill addresses.";
    const string LoseSession = "This deletes open tabs and the last session; it cannot be restored.";

    public static List<BrowserItem> Items(Browser b) => b.Kind == BrowserKind.Firefox ? FirefoxItems(b) : ChromiumItems(b);

    static List<BrowserItem> ChromiumItems(Browser b)
    {
        var profiles = b.Profiles().ToList();
        var locals = profiles.Select(p => b.LocalOf(p) ?? p).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        string[] cacheDirs = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", @"Service Worker\CacheStorage", @"Service Worker\ScriptCache"];
        return
        [
            new(b.Name, "cache", "Internet Cache", true, null, Files(b, "Internet Cache",
                [.. locals.SelectMany(p => cacheDirs.Select(d => Dir(Path.Join(p, d))))])),
            new(b.Name, "history", "Internet History", true, null, Files(b, "Internet History",
                [.. profiles.Select(p => Names(p, "History", "History-journal", "Visited Links", "Top Sites", "Top Sites-journal",
                    "Shortcuts", "Shortcuts-journal", "Network Action Predictor", "Network Action Predictor-journal"))])),
            new(b.Name, "downloads", "Download History", true, null, Files(b, "Download History", []),
                apply => Sql(profiles.Select(p => Path.Join(p, "History")), apply, "downloads", "downloads_url_chains", "downloads_slices")),
            new(b.Name, "lastdownload", "Last Download Location", true, null, Files(b, "Last Download Location", []),
                apply => profiles.Count(p => JsonRemove(Path.Join(p, "Preferences"), apply, "savefile", "default_directory"))),
            // Ticket 06 replaces this file deletion with row deletion that keeps whitelisted domains.
            new(b.Name, "cookies", "Cookies", true, null, Files(b, "Cookies",
                [.. profiles.SelectMany(p => new[] { Names(Path.Join(p, "Network"), "Cookies", "Cookies-journal"), Names(p, "Cookies", "Cookies-journal") })])),
            new(b.Name, "session", "Session", false, LoseSession, Files(b, "Session",
                [.. profiles.SelectMany(p => new[] { Dir(Path.Join(p, "Sessions")), Names(p, "Current Session", "Current Tabs", "Last Session", "Last Tabs") })])),
            new(b.Name, "forms", "Saved Form Information", false, LoseForms, Files(b, "Saved Form Information", []),
                apply => Sql(profiles.Select(p => Path.Join(p, "Web Data")), apply, "autofill", "autofill_profiles", "autofill_profile_names",
                    "autofill_profile_emails", "autofill_profile_phones", "autofill_profile_addresses", "local_addresses", "local_addresses_type_tokens")),
            new(b.Name, "passwords", "Saved Passwords", false, LoseLogins, Files(b, "Saved Passwords",
                [.. profiles.Select(p => Names(p, "Login Data", "Login Data-journal", "Login Data For Account", "Login Data For Account-journal"))])),
            new(b.Name, "compact", "Compact Databases", false, null, Files(b, "Compact Databases", []),
                apply => Vacuum(profiles.SelectMany(p => Names(p, "History", "Web Data", "Favicons", "Top Sites", "Shortcuts", "Login Data")
                    .Patterns.Select(n => Path.Join(p, n))), apply)),
        ];
    }

    static List<BrowserItem> FirefoxItems(Browser b)
    {
        var profiles = b.Profiles().ToList();
        var locals = profiles.Select(p => b.LocalOf(p) ?? p).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        string[] Db(string n) => [n, n + "-wal", n + "-shm", n + "-journal"];
        // places.sqlite also holds bookmarks, so history and downloads are rows, never the file.
        const string history = """
            DELETE FROM moz_historyvisits;
            DELETE FROM moz_inputhistory;
            DELETE FROM moz_places WHERE id NOT IN (SELECT fk FROM moz_bookmarks WHERE fk IS NOT NULL);
            """;
        const string downloads = "DELETE FROM moz_annos WHERE anno_attribute_id IN (SELECT id FROM moz_anno_attributes WHERE name LIKE 'downloads/%');";
        return
        [
            new(b.Name, "cache", "Internet Cache", true, null, Files(b, "Internet Cache",
                [.. locals.SelectMany(p => new[] { Dir(Path.Join(p, "cache2")), Dir(Path.Join(p, "startupCache")), Dir(Path.Join(p, "thumbnails")), Dir(Path.Join(p, "jumpListCache")) })])),
            new(b.Name, "history", "Internet History", true, null, Files(b, "Internet History", []),
                apply => SqlText(profiles.Select(p => Path.Join(p, "places.sqlite")), apply, "SELECT COUNT(*) FROM moz_historyvisits", history)),
            new(b.Name, "downloads", "Download History", true, null, Files(b, "Download History", []),
                apply => SqlText(profiles.Select(p => Path.Join(p, "places.sqlite")), apply,
                    "SELECT COUNT(*) FROM moz_annos WHERE anno_attribute_id IN (SELECT id FROM moz_anno_attributes WHERE name LIKE 'downloads/%')", downloads)),
            new(b.Name, "lastdownload", "Last Download Location", true, null, Files(b, "Last Download Location", []),
                apply => profiles.Count(p => PrefsRemove(Path.Join(p, "prefs.js"), apply, "browser.download.lastDir"))),
            // Ticket 06 replaces this file deletion with row deletion that keeps whitelisted domains.
            new(b.Name, "cookies", "Cookies", true, null, Files(b, "Cookies", [.. profiles.Select(p => Names(p, Db("cookies.sqlite")))])),
            new(b.Name, "session", "Session", false, LoseSession, Files(b, "Session",
                [.. profiles.SelectMany(p => new[] { Names(p, "sessionstore.jsonlz4", "sessionstore.js"), Dir(Path.Join(p, "sessionstore-backups")) })])),
            new(b.Name, "forms", "Saved Form Information", false, LoseForms, Files(b, "Saved Form Information",
                [.. profiles.Select(p => Names(p, Db("formhistory.sqlite")))])),
            new(b.Name, "passwords", "Saved Passwords", false, LoseLogins, Files(b, "Saved Passwords",
                [.. profiles.Select(p => Names(p, "logins.json", "logins-backup.json"))])),
            new(b.Name, "compact", "Compact Databases", false, null, Files(b, "Compact Databases", []),
                apply => Vacuum(profiles.SelectMany(p => SafeFiles(p, "*.sqlite")), apply)),
        ];
    }

    static FileKey Dir(string path) => new(path, ["*"], Recurse: true);
    static FileKey Names(string dir, params string[] names) => new(dir, names, Recurse: false);

    static Rule Files(Browser b, string item, FileKey[] keys)
    {
        var r = new Rule { Name = $"{b.Name}: {item}" };
        r.FileKeys.AddRange(keys);
        return r;
    }

    // apply=false counts rows; apply=true deletes them. Missing files/tables are skipped.
    static int Sql(IEnumerable<string> dbs, bool apply, params string[] tables)
    {
        var total = 0;
        foreach (var db in dbs.Where(File.Exists))
            total += WithDb(db, apply, c =>
            {
                var n = 0;
                foreach (var t in tables.Where(t => TableExists(c, t)))
                {
                    n += Scalar(c, $"SELECT COUNT(*) FROM \"{t}\"");
                    if (apply) Exec(c, $"DELETE FROM \"{t}\"");
                }
                return n;
            });
        return total;
    }

    static int SqlText(IEnumerable<string> dbs, bool apply, string count, string delete)
    {
        var total = 0;
        foreach (var db in dbs.Where(File.Exists))
            total += WithDb(db, apply, c =>
            {
                var n = Scalar(c, count);
                if (apply && n > 0) Exec(c, delete);
                return n;
            });
        return total;
    }

    static int Vacuum(IEnumerable<string> dbs, bool apply)
    {
        var list = dbs.Where(IsSqlite).ToList();
        if (apply) foreach (var db in list) WithDb(db, true, c => { Exec(c, "VACUUM"); return 0; });
        return list.Count;
    }

    static bool IsSqlite(string file)
    {
        try
        {
            if (!File.Exists(file)) return false;
            using var f = File.Open(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var head = new byte[16];
            return f.Read(head) == 16 && System.Text.Encoding.ASCII.GetString(head) == "SQLite format 3\0";
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
    }

    // A locked database (browser running) or a non-SQLite file counts as nothing instead of failing the whole clean.
    // Analyze opens read-only, so previewing never changes a browser file.
    static int WithDb(string db, bool write, Func<SqliteConnection, int> work)
    {
        try
        {
            using var c = new SqliteConnection(new SqliteConnectionStringBuilder
            {
                DataSource = db,
                Pooling = false,
                Mode = write ? SqliteOpenMode.ReadWrite : SqliteOpenMode.ReadOnly,
            }.ToString());
            c.Open();
            return work(c);
        }
        catch (SqliteException) { return 0; }
    }

    static bool TableExists(SqliteConnection c, string t)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=$t";
        cmd.Parameters.AddWithValue("$t", t);
        return cmd.ExecuteScalar() != null;
    }

    static int Scalar(SqliteConnection c, string sql)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = sql;
        return Convert.ToInt32(cmd.ExecuteScalar());
    }

    static void Exec(SqliteConnection c, string sql)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();
    }

    // Chromium Preferences is JSON: drop one nested key, keep the rest untouched.
    static bool JsonRemove(string file, bool apply, string parent, string key)
    {
        try
        {
            if (!File.Exists(file) || JsonNode.Parse(File.ReadAllText(file)) is not JsonObject root) return false;
            if (root[parent] is not JsonObject p || !p.ContainsKey(key)) return false;
            if (apply)
            {
                p.Remove(key);
                File.WriteAllText(file, root.ToJsonString());
            }
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Text.Json.JsonException) { return false; }
    }

    // Firefox prefs.js: one user_pref("name", ...) line per pref.
    static bool PrefsRemove(string file, bool apply, string pref)
    {
        try
        {
            if (!File.Exists(file)) return false;
            var lines = File.ReadAllLines(file);
            var keep = lines.Where(l => !l.TrimStart().StartsWith($"user_pref(\"{pref}\"", StringComparison.Ordinal)).ToArray();
            if (keep.Length == lines.Length) return false;
            if (apply) File.WriteAllLines(file, keep);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
    }

    static IEnumerable<string> SafeDirs(string dir)
    {
        try { return Directory.GetDirectories(dir); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return []; }
    }

    static IEnumerable<string> SafeFiles(string dir, string pattern)
    {
        try { return Directory.GetFiles(dir, pattern); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return []; }
    }
}
