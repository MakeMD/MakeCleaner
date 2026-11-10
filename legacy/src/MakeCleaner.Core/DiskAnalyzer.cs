namespace MakeCleaner;

public record DiskReport(Dictionary<string, List<FileInfo>> ByCategory)
{
    public long Bytes(string cat) => ByCategory.TryGetValue(cat, out var l) ? l.Sum(f => f.Length) : 0;
    public long Total => ByCategory.Values.Sum(l => l.Sum(f => f.Length));
}

public static class DiskAnalyzer
{
    public const string Other = "Other";

    // ponytail: extension table only; content sniffing if users complain about misfiled types
    static readonly (string Cat, string Exts)[] Table =
    [
        ("Pictures", "jpg jpeg png gif bmp tif tiff webp heic heif raw cr2 nef arw dng ico svg psd"),
        ("Music", "mp3 wav flac aac ogg oga wma m4a aif aiff opus mid midi ape alac"),
        ("Documents", "doc docx xls xlsx ppt pptx pdf txt rtf odt ods odp csv md epub djvu"),
        ("Video", "mp4 mkv avi mov wmv flv webm m4v mpg mpeg 3gp ts vob"),
        ("Compressed", "zip rar 7z tar gz tgz bz2 xz zst iso cab"),
        ("Email", "eml msg pst ost mbox"),
    ];

    public static readonly string[] Categories = [.. Table.Select(t => t.Cat), Other];

    static readonly Dictionary<string, string> ByExt = Table
        .SelectMany(t => t.Exts.Split(' ').Select(e => (Ext: "." + e, t.Cat)))
        .ToDictionary(x => x.Ext, x => x.Cat, StringComparer.OrdinalIgnoreCase);

    public static string CategoryOf(string path) => ByExt.GetValueOrDefault(Path.GetExtension(path), Other);

    public static DiskReport Analyze(IEnumerable<string> roots, CancellationToken ct = default, IProgress<int>? progress = null)
    {
        var report = Categories.ToDictionary(c => c, _ => new List<FileInfo>());
        foreach (var f in Scan.Files(roots, [], FileAttributes.ReparsePoint, ct, progress))
            report[CategoryOf(f.Name)].Add(f);
        return new DiskReport(report);
    }

    public static string ToText(DiskReport r) => string.Join(Environment.NewLine,
        Categories.Select(c => $"{c}\t{r.ByCategory[c].Count} files\t{r.Bytes(c)} bytes")
            .Append($"Total\t{r.ByCategory.Values.Sum(l => l.Count)} files\t{r.Total} bytes")
            .Append("")
            .Concat(r.ByCategory.SelectMany(kv => kv.Value.OrderByDescending(f => f.Length)
                .Select(f => $"{kv.Key}\t{f.Length}\t{f.FullName}"))));
}
