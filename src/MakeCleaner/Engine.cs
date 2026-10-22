namespace MakeCleaner;

public record CleanResult(int Deleted, long BytesFreed, int Skipped);

public static class Engine
{
    public const string BuiltInRules = """
        [Temporary Files]
        Default=True
        FileKey1=%TEMP%|*.*|RECURSE
        """;

    public static List<FileInfo> Analyze(Rule rule) => Analyze(rule, []);

    // extra = the user's global Exclude list (Options), applied on top of the rule's own ExcludeKeys.
    public static List<FileInfo> Analyze(Rule rule, IEnumerable<ExcludeKey> extra)
    {
        var found = new Dictionary<string, FileInfo>(StringComparer.OrdinalIgnoreCase);
        var excludes = FileExcludes(rule.Excludes.Concat(extra));
        foreach (var key in rule.FileKeys)
            foreach (var dir in Paths.ExpandDirs(key.Path)) // unknown env var or missing folder -> nothing
            {
                if (key.Recurse && Path.GetPathRoot(dir) == dir) continue; // never sweep a whole drive
                var opts = new EnumerationOptions
                {
                    RecurseSubdirectories = key.Recurse,
                    IgnoreInaccessible = true,
                    AttributesToSkip = FileAttributes.ReparsePoint, // never follow junctions/symlinks out of the target
                    MatchType = MatchType.Win32,
                };
                foreach (var pattern in key.Patterns)
                    try
                    {
                        foreach (var f in new DirectoryInfo(dir).EnumerateFiles(pattern.Trim(), opts))
                            if (!excludes.Any(x => x(f.FullName)) && (key.OlderThanHours == 0 || f.LastWriteTimeUtc < DateTime.UtcNow.AddHours(-key.OlderThanHours)))
                                found.TryAdd(f.FullName, f);
                    }
                    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            }
        return [.. found.Values];
    }

    // FILE: name match directly in dir; PATH: anywhere under dir (no patterns = everything).
    static List<Func<string, bool>> FileExcludes(IEnumerable<ExcludeKey> excludes)
    {
        var list = new List<Func<string, bool>>();
        foreach (var x in excludes.Where(x => x.Kind is "FILE" or "PATH"))
            foreach (var dir in Paths.ExpandDirs(x.Path))
            {
                var prefix = dir.TrimEnd('\\') + "\\";
                var pats = x.Patterns.Length > 0 ? x.Patterns : ["*"];
                list.Add(x.Kind == "FILE"
                    ? f => string.Equals(Path.GetDirectoryName(f) + "\\", prefix, StringComparison.OrdinalIgnoreCase) && pats.Any(p => Paths.Matches(p, Path.GetFileName(f)))
                    : f => f.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) && pats.Any(p => Paths.Matches(p, Path.GetFileName(f))));
            }
        return list;
    }

    public static List<RegKey> AnalyzeRegistry(Rule rule) => AnalyzeRegistry(rule, []);

    public static List<RegKey> AnalyzeRegistry(Rule rule, IEnumerable<ExcludeKey> extra)
    {
        var regEx = rule.Excludes.Concat(extra).Where(x => x.Kind == "REG").Select(x => RegKey.Parse(x.Path + (x.Patterns.Length > 0 ? "|" + x.Patterns[0] : ""))).ToList();
        bool Excluded(RegKey t) => regEx.Any(x =>
            (t.Key.Equals(x.Key, StringComparison.OrdinalIgnoreCase) || t.Key.StartsWith(x.Key.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase))
            && (x.Value == null || string.Equals(x.Value, t.Value, StringComparison.OrdinalIgnoreCase)));
        return [.. rule.RegKeys.Where(t => !Excluded(t) && Reg.Exists(t))];
    }

    public static CleanResult CleanRegistry(IEnumerable<RegKey> targets)
    {
        int deleted = 0, skipped = 0;
        foreach (var t in targets)
            if (Reg.Delete(t)) deleted++; else skipped++;
        return new CleanResult(deleted, 0, skipped);
    }

    // After Clean: REMOVESELF folders go only if nothing is left inside (locked/excluded files keep them).
    public static int RemoveEmptyDirs(Rule rule)
    {
        int removed = 0;
        foreach (var key in rule.FileKeys.Where(k => k.RemoveSelf))
            foreach (var dir in Paths.ExpandDirs(key.Path))
            {
                if (Path.GetPathRoot(dir) == dir) continue;
                var opts = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint };
                List<string> dirs; // deepest first, so emptied children make their parents empty
                try { dirs = [.. Directory.EnumerateDirectories(dir, "*", opts).OrderByDescending(d => d.Length).Append(dir)]; }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { continue; }
                foreach (var d in dirs)
                    try
                    {
                        if (!Directory.EnumerateFileSystemEntries(d).Any()) { Directory.Delete(d); removed++; }
                    }
                    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            }
        return removed;
    }

    // Deletes exactly the files Analyze returned; locked/denied ones are skipped and counted.
    // passes > 0 = secure deletion (see SecureDelete.Methods).
    public static CleanResult Clean(IEnumerable<FileInfo> files, int passes = 0)
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
                SecureDelete.Delete(f.FullName, passes);
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
