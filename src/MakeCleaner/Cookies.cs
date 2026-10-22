namespace MakeCleaner;

// Cookie keep-list (Options > Cookies): domains whose cookies every browser clean leaves alone.
public static class Cookies
{
    public const string KeepPrefix = "KeepCookie";

    // ponytail: one global hook, set from Settings in Program, so the GUI and /auto read the same live list;
    // pass the list in explicitly if a second Settings instance ever appears.
    public static Func<IReadOnlyCollection<string>> Keep { get; set; } = () => [];

    // ".www.Example.com" -> "example.com": the form shown in lists and stored in the keep-list.
    public static string Normalize(string host)
    {
        var h = host.Trim().TrimStart('.').ToLowerInvariant();
        return h.StartsWith("www.", StringComparison.Ordinal) ? h[4..] : h;
    }

    // Keeping example.com keeps .example.com, www.example.com and every other subdomain, but not badexample.com.
    public static bool IsKept(string? host, IReadOnlyCollection<string> keep)
    {
        if (host == null || keep.Count == 0) return false;
        var h = host.Trim().TrimStart('.').ToLowerInvariant();
        foreach (var k in keep)
        {
            var d = Normalize(k);
            if (d.Length > 0 && (h == d || h.EndsWith("." + d, StringComparison.Ordinal))) return true;
        }
        return false;
    }

    // Import/export format: one domain per line, # comments and blank lines ignored.
    public static List<string> Parse(IEnumerable<string> lines) =>
        [.. lines.Select(l => l.Split('#')[0]).Select(Normalize).Where(d => d.Length > 0).Distinct().Order(StringComparer.Ordinal)];
}
