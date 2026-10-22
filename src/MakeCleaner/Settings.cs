namespace MakeCleaner;

// Flat key=value ini. portable.dat next to the exe -> ini next to the exe, else %AppData%\MakeCleaner.
public class Settings
{
    public const string FileName = "MakeCleaner.ini";
    public string Path { get; }
    readonly Dictionary<string, string> values = new(StringComparer.OrdinalIgnoreCase);

    public Settings(string dir)
    {
        Path = System.IO.Path.Combine(dir, FileName);
        if (!File.Exists(Path)) return;
        foreach (var line in File.ReadAllLines(Path))
        {
            var eq = line.IndexOf('=');
            if (eq > 0) values[line[..eq]] = line[(eq + 1)..];
        }
    }

    public static string ResolveDir(string exeDir) =>
        File.Exists(System.IO.Path.Combine(exeDir, "portable.dat"))
            ? exeDir
            : System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MakeCleaner");

    public bool GetBool(string key, bool fallback) =>
        values.TryGetValue(key, out var v) && bool.TryParse(v, out var b) ? b : fallback;

    public string Get(string key, string fallback = "") => values.TryGetValue(key, out var v) ? v : fallback;
    public int GetInt(string key, int fallback) =>
        values.TryGetValue(key, out var v) && int.TryParse(v, out var i) ? i : fallback;

    public void Set(string key, object value) => values[key] = value.ToString()!;

    // Lists as numbered keys: Include1=..., Include2=...
    public List<string> GetList(string prefix) =>
        [.. Enumerable.Range(1, int.MaxValue).Select(i => Get(prefix + i)).TakeWhile(v => v.Length > 0)];

    public void SetList(string prefix, IEnumerable<string> items)
    {
        foreach (var k in values.Keys.Where(k => k.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
                     && int.TryParse(k[prefix.Length..], out _)).ToList())
            values.Remove(k);
        var n = 0;
        foreach (var v in items) values[prefix + ++n] = v;
    }

    public void Save()
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
        File.WriteAllLines(Path, ["[Options]", .. values.Select(kv => $"{kv.Key}={kv.Value}")]);
    }
}
