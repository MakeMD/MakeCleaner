using System.Security.Cryptography;

namespace MakeCleaner;

public record DupOptions
{
    public string[] Include { get; init; } = [];
    public string[] Exclude { get; init; } = [];
    public bool ByName { get; init; } = true;
    public bool BySize { get; init; } = true;
    public bool ByDate { get; init; } = true;
    public bool ByContent { get; init; }
    public bool IgnoreEmpty { get; init; } = true;
    public bool IgnoreSystem { get; init; } = true;
    public bool IgnoreHidden { get; init; } = true;
    public bool IgnoreReadOnly { get; init; }
    public long MinSize { get; init; }
    public long MaxSize { get; init; } = long.MaxValue;
}

public record DupResult(List<List<FileInfo>> Groups, int Hashed);

public static class Duplicates
{
    // Groups files by the chosen keys; content compare hashes only files that already share a size.
    public static DupResult Find(DupOptions o, CancellationToken ct = default, IProgress<int>? progress = null)
    {
        var skip = FileAttributes.ReparsePoint
            | (o.IgnoreSystem ? FileAttributes.System : 0)
            | (o.IgnoreHidden ? FileAttributes.Hidden : 0);
        var files = Scan.Files(o.Include, o.Exclude, skip, ct, progress)
            .Where(f => f.Length >= o.MinSize && f.Length <= o.MaxSize)
            .Where(f => !(o.IgnoreEmpty && f.Length == 0))
            .Where(f => !(o.IgnoreReadOnly && f.IsReadOnly));

        var sizeKey = o.BySize || o.ByContent;
        var groups = files
            .GroupBy(f => (
                Name: o.ByName ? f.Name.ToUpperInvariant() : "",
                Size: sizeKey ? f.Length : -1,
                Date: o.ByDate ? f.LastWriteTimeUtc.Ticks : -1))
            .Where(g => g.Count() > 1)
            .Select(g => g.ToList())
            .ToList();
        if (!o.ByContent) return new(groups, 0);

        int hashed = 0;
        var byContent = new List<List<FileInfo>>();
        foreach (var g in groups)
        {
            var hashes = new Dictionary<string, List<FileInfo>>();
            foreach (var f in g)
            {
                ct.ThrowIfCancellationRequested();
                var h = Hash(f, ct);
                if (h == null) continue; // unreadable: not a provable duplicate
                hashed++;
                if (!hashes.TryGetValue(h, out var list)) hashes[h] = list = [];
                list.Add(f);
            }
            byContent.AddRange(hashes.Values.Where(l => l.Count > 1));
        }
        return new(byContent, hashed);
    }

    // Default selection: everything except the first file of each group.
    public static List<FileInfo> AllButFirst(IEnumerable<List<FileInfo>> groups) => [.. groups.SelectMany(g => g.Skip(1))];

    static string? Hash(FileInfo f, CancellationToken ct)
    {
        try
        {
            using var s = f.OpenRead();
            using var h = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buf = new byte[1 << 20];
            int n;
            while ((n = s.Read(buf)) > 0)
            {
                ct.ThrowIfCancellationRequested(); // cancel mid-file, big files stay responsive
                h.AppendData(buf, 0, n);
            }
            return Convert.ToHexString(h.GetHashAndReset());
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }
}

// Shared walker for the Tools scanners: roots minus excluded folders, no junction hopping.
public static class Scan
{
    public static IEnumerable<FileInfo> Files(IEnumerable<string> roots, IEnumerable<string> exclude, FileAttributes skip,
        CancellationToken ct, IProgress<int>? progress = null)
    {
        var ex = exclude.Select(Norm).Where(p => p.Length > 1).ToList();
        var opts = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = skip };
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        int count = 0;
        foreach (var root in roots.Select(r => Environment.ExpandEnvironmentVariables(r.Trim())).Where(Directory.Exists))
            foreach (var f in new DirectoryInfo(root).EnumerateFiles("*", opts))
            {
                ct.ThrowIfCancellationRequested();
                if (ex.Any(e => f.FullName.StartsWith(e, StringComparison.OrdinalIgnoreCase)) || !seen.Add(f.FullName)) continue;
                if (++count % 500 == 0) progress?.Report(count);
                yield return f;
            }
        progress?.Report(count);
    }

    static string Norm(string p) => Path.TrimEndingDirectorySeparator(Environment.ExpandEnvironmentVariables(p.Trim())) + Path.DirectorySeparatorChar;

    public static string[] SplitPaths(string text) => text.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
}
