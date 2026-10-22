using MakeCleaner;

public class DuplicatesTests : IDisposable
{
    readonly string dir = Directory.CreateTempSubdirectory("mc-tools-").FullName;

    public void Dispose()
    {
        foreach (var f in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories)) File.SetAttributes(f, FileAttributes.Normal);
        Directory.Delete(dir, true);
    }

    string Put(string rel, string content)
    {
        var p = Path.Combine(dir, rel);
        Directory.CreateDirectory(Path.GetDirectoryName(p)!);
        File.WriteAllText(p, content);
        return p;
    }

    DupOptions ContentOnly => new() { Include = [dir], ByName = false, BySize = false, ByDate = false, ByContent = true };

    static string[][] Names(DupResult r) =>
        [.. r.Groups.Select(g => g.Select(f => f.Name).Order(StringComparer.Ordinal).ToArray()).OrderBy(g => g[0], StringComparer.Ordinal)];

    [Fact]
    public void Content_duplicates_found_despite_different_names()
    {
        Put("a.txt", "same bytes");
        Put(@"sub\b.dat", "same bytes");
        Put("c.txt", "diff bytes"); // same size, different content
        Put("d.txt", "unique");

        var r = Duplicates.Find(ContentOnly);
        Assert.Equal([["a.txt", "b.dat"]], Names(r));
    }

    [Fact]
    public void Only_same_size_files_are_hashed()
    {
        Put("a.txt", "12345");
        Put("b.txt", "12345");
        Put("c.txt", "1234567"); // unique size -> never opened
        Put("d.txt", "123456789");
        Assert.Equal(2, Duplicates.Find(ContentOnly).Hashed);
    }

    [Fact]
    public void Name_and_size_match_without_content_and_ignores_apply()
    {
        Put(@"x\report.txt", "aaaa");
        Put(@"y\REPORT.txt", "bbbb"); // same name (case-insensitive) + size, different content
        Put(@"x\empty.log", "");
        Put(@"y\empty.log", "");
        var hidden1 = Put(@"x\h.bin", "zz");
        var hidden2 = Put(@"y\h.bin", "zz");
        File.SetAttributes(hidden1, FileAttributes.Hidden);
        File.SetAttributes(hidden2, FileAttributes.Hidden);

        var r = Duplicates.Find(new DupOptions { Include = [dir], ByDate = false });
        Assert.Equal([["REPORT.txt", "report.txt"]], Names(r));
    }

    [Fact]
    public void Size_limits_and_exclude_folders()
    {
        Put(@"keep\a.bin", "1234567890");
        Put(@"keep\b.bin", "1234567890");
        Put(@"skip\c.bin", "1234567890");
        Put(@"keep\s1.bin", "1");
        Put(@"keep\s2.bin", "1");

        var r = Duplicates.Find(ContentOnly with { Exclude = [Path.Combine(dir, "skip")], MinSize = 5 });
        Assert.Equal([["a.bin", "b.bin"]], Names(r));
    }

    [Fact]
    public void Delete_selection_keeps_one_copy_per_group()
    {
        var a = Put("a.txt", "dup");
        var b = Put(@"s\b.txt", "dup");
        var c = Put(@"t\c.txt", "dup");

        var r = Duplicates.Find(ContentOnly);
        var res = Engine.Clean(Duplicates.AllButFirst(r.Groups));
        Assert.Equal(2, res.Deleted);
        Assert.Equal(1, new[] { a, b, c }.Count(File.Exists));
    }

    [Fact]
    public void Cancel_stops_scan()
    {
        Put("a.txt", "x");
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        Assert.Throws<OperationCanceledException>(() => Duplicates.Find(ContentOnly, cts.Token));
        Assert.Throws<OperationCanceledException>(() => DiskAnalyzer.Analyze([dir], cts.Token));
    }

    [Fact]
    public void Disk_analyzer_sums_by_category()
    {
        Put("photo.JPG", "12345");
        Put(@"m\song.mp3", "123");
        Put(@"m\song2.flac", "12");
        Put("notes.docx", "1");
        Put("mail.eml", "1234");
        Put("thing.xyz", "12345678");

        var r = DiskAnalyzer.Analyze([dir]);
        Assert.Equal(5, r.Bytes("Pictures"));
        Assert.Equal(5, r.Bytes("Music"));
        Assert.Equal(1, r.Bytes("Documents"));
        Assert.Equal(4, r.Bytes("Email"));
        Assert.Equal(8, r.Bytes(DiskAnalyzer.Other));
        Assert.Equal(23, r.Total);
        Assert.Contains("thing.xyz", DiskAnalyzer.ToText(r));
    }
}
