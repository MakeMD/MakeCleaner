namespace MakeCleaner;

// One winapp2 FileKey: "path|pattern[;pattern]|RECURSE"
public record FileKey(string Path, string[] Patterns, bool Recurse)
{
    public static FileKey Parse(string value)
    {
        var parts = value.Split('|');
        var patterns = parts.Length > 1 && parts[1].Length > 0 ? parts[1].Split(';') : ["*.*"];
        var recurse = parts.Length > 2 && parts[2].Equals("RECURSE", StringComparison.OrdinalIgnoreCase);
        return new FileKey(parts[0].Trim(), patterns, recurse);
    }
}

// One checkbox = one INI section.
// ponytail: only FileKey for now; full winapp2 syntax lands in ticket 02.
public record Rule(string Name, List<FileKey> FileKeys)
{
    public static List<Rule> ParseIni(string text)
    {
        var rules = new List<Rule>();
        Rule? cur = null;
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line[0] == ';') continue;
            if (line[0] == '[' && line[^1] == ']')
            {
                cur = new Rule(line[1..^1], []);
                rules.Add(cur);
                continue;
            }
            var eq = line.IndexOf('=');
            if (cur == null || eq < 0) continue;
            if (line[..eq].StartsWith("FileKey", StringComparison.OrdinalIgnoreCase))
                cur.FileKeys.Add(FileKey.Parse(line[(eq + 1)..]));
        }
        return rules;
    }
}

public record CleanResult(int Deleted, long BytesFreed, int Skipped);

public static class Engine
{
    public const string BuiltInRules = """
        [Temporary Files]
        FileKey1=%TEMP%|*.*|RECURSE
        """;

    public static List<FileInfo> Analyze(Rule rule)
    {
        var found = new Dictionary<string, FileInfo>(StringComparer.OrdinalIgnoreCase);
        foreach (var key in rule.FileKeys)
        {
            var dir = Environment.ExpandEnvironmentVariables(key.Path);
            if (dir.Contains('%') || !Directory.Exists(dir)) continue; // unknown env var or missing folder
            var opts = new EnumerationOptions
            {
                RecurseSubdirectories = key.Recurse,
                IgnoreInaccessible = true,
                AttributesToSkip = FileAttributes.ReparsePoint, // never follow junctions/symlinks out of the target
                MatchType = MatchType.Win32,
            };
            foreach (var pattern in key.Patterns)
                foreach (var f in new DirectoryInfo(dir).EnumerateFiles(pattern.Trim(), opts))
                    found.TryAdd(f.FullName, f);
        }
        return [.. found.Values];
    }

    // Deletes exactly the files Analyze returned; locked/denied ones are skipped and counted.
    public static CleanResult Clean(IEnumerable<FileInfo> files)
    {
        int deleted = 0, skipped = 0;
        long bytes = 0;
        foreach (var f in files)
        {
            try
            {
                f.Refresh();
                if (!f.Exists) continue;
                var len = f.Length;
                if (f.IsReadOnly) f.IsReadOnly = false;
                f.Delete();
                deleted++;
                bytes += len;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                skipped++;
            }
        }
        return new CleanResult(deleted, bytes, skipped);
    }
}
