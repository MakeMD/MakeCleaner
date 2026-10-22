using System.IO.Enumeration;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace MakeCleaner;

// "path|pattern[;pattern]|RECURSE|REMOVESELF". REMOVESELF implies recursion and also drops the (emptied) folder.
// OLDER=hours (MakeCleaner extension, used by Options > Include) skips files modified more recently.
public record FileKey(string Path, string[] Patterns, bool Recurse, bool RemoveSelf = false, int OlderThanHours = 0)
{
    public static FileKey Parse(string value)
    {
        var parts = value.Split('|');
        var patterns = parts.Length > 1 && parts[1].Length > 0 ? parts[1].Split(';') : ["*.*"];
        bool Flag(string f) => parts.Skip(2).Any(p => p.Trim().Equals(f, StringComparison.OrdinalIgnoreCase));
        var removeSelf = Flag("REMOVESELF");
        var older = parts.Skip(2).Select(p => p.Trim()).FirstOrDefault(p => p.StartsWith("OLDER=", StringComparison.OrdinalIgnoreCase));
        return new FileKey(parts[0].Trim(), patterns, removeSelf || Flag("RECURSE"), removeSelf,
            older != null && int.TryParse(older[6..], out var h) && h > 0 ? h : 0);
    }
}

// "HKCU\key" = whole key, "HKCU\key|Value" = one value.
public record RegKey(string Key, string? Value)
{
    public static RegKey Parse(string value)
    {
        var bar = value.IndexOf('|');
        return bar < 0 ? new(value.Trim(), null) : new(value[..bar].Trim(), value[(bar + 1)..]);
    }

    public override string ToString() => Value == null ? Key : $"{Key}|{Value}";
}

// "FILE|dir|patterns" = files directly in dir, "PATH|dir|patterns" = anywhere under dir, "REG|key[|value]".
public record ExcludeKey(string Kind, string Path, string[] Patterns)
{
    public static ExcludeKey Parse(string value)
    {
        var parts = value.Split('|');
        var rest = parts.Length > 1 ? parts[1].Trim() : "";
        var third = parts.Length > 2 && parts[2].Length > 0 ? parts[2].Split(';') : [];
        return new(parts[0].Trim().ToUpperInvariant(), rest, third);
    }
}

// One checkbox = one INI section (winapp2 format, keys case-insensitive and numbered: FileKey1..n).
public class Rule
{
    public string Name { get; init; } = "";
    public string? Section { get; set; }
    public int? LangSecRef { get; set; }
    public bool Default { get; set; }
    public string? Warning { get; set; }
    public string? DetectOS { get; set; }
    public List<FileKey> FileKeys { get; } = [];
    public List<RegKey> RegKeys { get; } = [];
    public List<ExcludeKey> Excludes { get; } = [];
    public List<string> Detect { get; } = [];
    public List<string> DetectFile { get; } = [];
    public List<string> SpecialDetect { get; } = [];

    // Public winapp2 LangSecRef groups; Section= (free text) wins when present.
    public string Group => Section ?? LangSecRef switch
    {
        3021 => "Applications",
        3022 => "Internet",
        3023 => "Multimedia",
        3024 => "Utilities",
        3025 => "Windows",
        _ => "Other",
    };

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
                cur = new Rule { Name = line[1..^1] };
                rules.Add(cur);
                continue;
            }
            var eq = line.IndexOf('=');
            if (cur == null || eq < 0) continue;
            var val = line[(eq + 1)..].Trim();
            switch (line[..eq].TrimEnd().TrimEnd("0123456789".ToCharArray()).ToLowerInvariant())
            {
                case "filekey": cur.FileKeys.Add(FileKey.Parse(val)); break;
                case "regkey": cur.RegKeys.Add(RegKey.Parse(val)); break;
                case "excludekey": cur.Excludes.Add(ExcludeKey.Parse(val)); break;
                case "detect": cur.Detect.Add(val); break;
                case "detectfile": cur.DetectFile.Add(val); break;
                case "specialdetect": cur.SpecialDetect.Add(val); break;
                case "detectos": cur.DetectOS = val; break;
                case "default": cur.Default = val.Equals("true", StringComparison.OrdinalIgnoreCase); break;
                case "warning": cur.Warning = val; break;
                case "section": cur.Section = val; break;
                case "langsecref": cur.LangSecRef = int.TryParse(val, out var n) ? n : null; break;
            }
        }
        return rules;
    }

    // Shown only if the OS fits and (no detection keys, or any of them hits).
    public bool IsDetected()
    {
        if (DetectOS != null && !Paths.OsInRange(DetectOS, Environment.OSVersion.Version)) return false;
        if (Detect.Count + DetectFile.Count + SpecialDetect.Count == 0) return true;
        return Detect.Any(Reg.KeyExists) || DetectFile.Any(Paths.AnyExists) || SpecialDetect.Any(Paths.SpecialDetect);
    }

    // Bundled community Winapp2.ini (rules\) + optional user winapp2.ini next to the exe; user entries override by name.
    public static List<Rule> LoadApplications(string exeDir)
    {
        var byName = new Dictionary<string, Rule>(StringComparer.OrdinalIgnoreCase);
        foreach (var file in new[] { Path.Combine(exeDir, "rules", "Winapp2.ini"), Path.Combine(exeDir, "winapp2.ini") })
            if (File.Exists(file))
                foreach (var r in ParseIni(File.ReadAllText(file))) byName[r.Name] = r;
        return [.. byName.Values.Where(r => r.IsDetected()).OrderBy(r => r.Group).ThenBy(r => r.Name)];
    }
}

public static partial class Paths
{
    [GeneratedRegex("%([A-Za-z0-9_]+)%")]
    private static partial Regex VarRx();

    // winapp2 vars that are not real env vars, or mean more than one folder.
    static string[] VarValues(string name)
    {
        string F(Environment.SpecialFolder f) => Environment.GetFolderPath(f);
        string[] v = name.ToLowerInvariant() switch
        {
            "programfiles" => [F(Environment.SpecialFolder.ProgramFiles), F(Environment.SpecialFolder.ProgramFilesX86)],
            "commonprogramfiles" => [F(Environment.SpecialFolder.CommonProgramFiles), F(Environment.SpecialFolder.CommonProgramFilesX86)],
            "locallowappdata" => [Path.Combine(F(Environment.SpecialFolder.UserProfile), "AppData", "LocalLow")],
            "documents" or "mydocuments" => [F(Environment.SpecialFolder.MyDocuments)],
            "commonappdata" => [F(Environment.SpecialFolder.CommonApplicationData)],
            _ => [Environment.GetEnvironmentVariable(name) ?? ""],
        };
        return [.. v.Where(s => s.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase)];
    }

    // Expands vars (unknown var -> no results). One input can yield several paths (%ProgramFiles% = x64 + x86).
    public static IEnumerable<string> ExpandVars(string path)
    {
        var m = VarRx().Match(path);
        if (!m.Success) { yield return path; yield break; }
        foreach (var v in VarValues(m.Groups[1].Value))
            foreach (var rest in ExpandVars(path[(m.Index + m.Length)..]))
                yield return path[..m.Index] + v + rest;
    }

    static bool IsWild(string s) => s.IndexOfAny(['*', '?']) >= 0;

    // Existing directories matching path; '*' / '?' allowed in any segment. Wildcards never descend into junctions.
    public static IEnumerable<string> ExpandDirs(string path)
    {
        foreach (var p in ExpandVars(path))
        {
            var segs = p.Trim().TrimEnd('\\').Split('\\');
            if (segs[0].Length == 0) continue; // UNC / relative: not supported
            IEnumerable<string> cur = [segs[0] + "\\"];
            foreach (var seg in segs.Skip(1).Where(s => s.Length > 0))
                cur = IsWild(seg) ? cur.SelectMany(d => SafeDirs(d, seg)) : cur.Select(d => Path.Combine(d, seg));
            foreach (var d in cur)
                if (Directory.Exists(d)) yield return d;
        }
    }

    static IEnumerable<string> SafeDirs(string dir, string pattern)
    {
        if (!Directory.Exists(dir)) return [];
        try
        {
            return new DirectoryInfo(dir).EnumerateDirectories(pattern, new EnumerationOptions
            {
                IgnoreInaccessible = true,
                AttributesToSkip = FileAttributes.ReparsePoint,
                MatchType = MatchType.Win32,
            }).Select(d => d.FullName).ToList();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return []; }
    }

    // DetectFile: file or folder exists; wildcards allowed in every segment incl. the last.
    public static bool AnyExists(string path)
    {
        var trimmed = path.Trim().TrimEnd('\\');
        var cut = trimmed.LastIndexOf('\\');
        if (cut < 0) return false;
        var leaf = trimmed[(cut + 1)..];
        foreach (var dir in ExpandDirs(trimmed[..cut]))
        {
            try
            {
                if (IsWild(leaf) ? Directory.EnumerateFileSystemEntries(dir, leaf).Any() : Path.Exists(Path.Combine(dir, leaf)))
                    return true;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        return false;
    }

    public static bool Matches(string pattern, string name) => FileSystemName.MatchesWin32Expression(pattern.Trim(), name);

    // DetectOS "min|max", either side optional; compares only as many version parts as given.
    public static bool OsInRange(string range, Version os)
    {
        var parts = range.Split('|');
        int Cmp(string v)
        {
            var want = Version.Parse(v.Trim().Contains('.') ? v.Trim() : v.Trim() + ".0");
            var have = want.Build < 0 ? new Version(os.Major, os.Minor) : new Version(os.Major, os.Minor, Math.Max(os.Build, 0));
            return have.CompareTo(want);
        }
        var min = parts[0].Trim();
        var max = parts.Length > 1 ? parts[1].Trim() : min;
        return (min.Length == 0 || Cmp(min) >= 0) && (max.Length == 0 || Cmp(max) <= 0);
    }

    // ponytail: only the core browsers; unknown DET_* hides the entry. Ticket 05 owns real browser detection.
    public static bool SpecialDetect(string id) => id.Trim().ToUpperInvariant() switch
    {
        "DET_CHROME" => AnyExists(@"%LocalAppData%\Google\Chrome\User Data"),
        "DET_MOZILLA" => AnyExists(@"%AppData%\Mozilla\Firefox"),
        "DET_THUNDERBIRD" => AnyExists(@"%AppData%\Thunderbird"),
        "DET_OPERA" => AnyExists(@"%AppData%\Opera Software"),
        _ => false,
    };
}
