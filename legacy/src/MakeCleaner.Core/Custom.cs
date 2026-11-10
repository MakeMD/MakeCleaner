namespace MakeCleaner;

// Options > Include / Exclude. Stored as numbered ini keys (Include1.., Exclude1..) in winapp2 syntax,
// so they run through the same FileKey / ExcludeKey code as every other rule.
//   Include: "dir|patterns[|RECURSE|REMOVESELF][|OLDER=hours]"
//   Exclude: "PATH|dir" (folder), "FILE|dir|name" (file), "REG|key[|value]"
public static class Custom
{
    public const string RuleName = "Custom Files and Folders";
    public const string IncludePrefix = "Include", ExcludePrefix = "Exclude";

    public static Rule IncludeRule(Settings s)
    {
        var rule = new Rule { Name = RuleName };
        // re-checked on every load: a hand-edited ini must not sneak in C:\ or %windir%
        foreach (var e in s.GetList(IncludePrefix))
            if (FileKey.Parse(e) is var k && Reject(k.Path) == null) rule.FileKeys.Add(k);
        return rule;
    }

    public static List<ExcludeKey> Excludes(Settings s) => [.. s.GetList(ExcludePrefix).Select(ExcludeKey.Parse)];

    // Registry cleaner matches excludes as "key" or "key\value" prefixes.
    public static List<string> RegistryExcludes(Settings s) =>
        [.. Excludes(s).Where(x => x.Kind == "REG").Select(x => x.Patterns.Length > 0 ? $@"{x.Path}\{x.Patterns[0]}" : x.Path)];

    public static void AddExclude(Settings s, string entry)
    {
        s.SetList(ExcludePrefix, s.GetList(ExcludePrefix).Append(entry).Distinct(StringComparer.OrdinalIgnoreCase));
        s.Save();
    }

    // null = ok to clean; otherwise why not. Blocks drive roots, anything under %windir%,
    // and any folder that is (or contains) Program Files, ProgramData, Users or the user profile.
    public static string? Reject(string path)
    {
        string full;
        try
        {
            var expanded = Environment.ExpandEnvironmentVariables(path.Trim());
            if (!Path.IsPathFullyQualified(expanded)) return "Use a full path like D:\\Folder.";
            full = Path.GetFullPath(expanded).TrimEnd('\\');
        }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { return "Not a valid path."; }

        if (full.Length <= 2 || full.StartsWith(@"\\")) return "A whole drive or network share cannot be cleaned.";
        string F(Environment.SpecialFolder f) => Environment.GetFolderPath(f).TrimEnd('\\');
        var windir = F(Environment.SpecialFolder.Windows);
        if (Under(full, windir)) return "The Windows folder is protected.";
        var profile = F(Environment.SpecialFolder.UserProfile);
        foreach (var p in new[] { F(Environment.SpecialFolder.ProgramFiles), F(Environment.SpecialFolder.ProgramFilesX86),
                     F(Environment.SpecialFolder.CommonApplicationData), profile, Path.GetDirectoryName(profile)! })
            if (p.Length > 0 && Under(p, full)) return $"This would clean the system folder {p}.";
        return null;
    }

    static bool Under(string path, string dir) =>
        path.Equals(dir, StringComparison.OrdinalIgnoreCase) || path.StartsWith(dir + @"\", StringComparison.OrdinalIgnoreCase);
}
