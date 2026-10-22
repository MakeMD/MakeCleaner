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

    public int GetInt(string key, int fallback) =>
        values.TryGetValue(key, out var v) && int.TryParse(v, out var i) ? i : fallback;

    public void Set(string key, object value) => values[key] = value.ToString()!;

    public void Save()
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
        File.WriteAllLines(Path, ["[Options]", .. values.Select(kv => $"{kv.Key}={kv.Value}")]);
    }
}
