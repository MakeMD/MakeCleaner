using MakeCleaner;

public class SecureDeleteTests : IDisposable
{
    readonly string dir = Directory.CreateTempSubdirectory("mc-sd-").FullName;

    public void Dispose() => Directory.Delete(dir, true);

    string Secret(int bytes = 5000)
    {
        var p = Path.Combine(dir, "secret.txt");
        File.WriteAllBytes(p, [.. Enumerable.Range(0, bytes).Select(i => (byte)('A' + i % 26))]);
        return p;
    }

    [Theory]
    [InlineData(1, 0x00)]
    [InlineData(3, -1)] // last DoD pass is random
    [InlineData(7, -1)]
    [InlineData(35, -1)]
    public void Overwrite_replaces_every_byte_and_keeps_length(int passes, int lastByte)
    {
        var p = Secret();
        var before = File.ReadAllBytes(p);
        SecureDelete.Overwrite(p, passes);
        var after = File.ReadAllBytes(p);
        Assert.Equal(before.Length, after.Length);
        if (lastByte >= 0) Assert.All(after, b => Assert.Equal((byte)lastByte, b));
        else Assert.True(after.Where((b, i) => b == before[i]).Count() < before.Length / 20); // random: ~1/256 coincidences
    }

    [Fact]
    public void Pass_counts_match_methods()
    {
        foreach (var (passes, _) in SecureDelete.Methods.Where(m => m.Passes > 0))
            Assert.Equal(passes, SecureDelete.Patterns(passes).Length);
    }

    [Fact]
    public void Secure_clean_deletes_file_and_leaves_nothing_behind()
    {
        Secret();
        var r = Engine.Clean(new DirectoryInfo(dir).GetFiles(), passes: 3);
        Assert.Equal((1, 5000L, 0), (r.Deleted, r.BytesFreed, r.Skipped));
        Assert.Empty(Directory.EnumerateFileSystemEntries(dir));
    }

    [Fact]
    public void Wipe_free_space_writes_and_removes_its_files()
    {
        Directory.CreateDirectory(Path.Combine(dir, SecureDelete.WipeDirPrefix + "stale")); // leftover of a killed run
        var written = SecureDelete.WipeFreeSpace(dir, 3, limitBytes: 3 << 20);
        Assert.Equal(3L << 20, written);
        Assert.Empty(Directory.EnumerateFileSystemEntries(dir));
    }

    [Fact]
    public void Wipe_cancel_still_cleans_up()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        Assert.Throws<OperationCanceledException>(() => SecureDelete.WipeFreeSpace(dir, 1, ct: cts.Token, limitBytes: 1 << 20));
        Assert.Empty(Directory.EnumerateFileSystemEntries(dir));
    }

    [Fact]
    public void System_drive_and_own_drive_cannot_be_erased_entirely()
    {
        Assert.NotNull(DriveWiperPanel.CheckErasable(@"C:\", @"C:\", @"D:\"));
        Assert.NotNull(DriveWiperPanel.CheckErasable(@"d:\", @"C:\", @"D:\"));
        Assert.Null(DriveWiperPanel.CheckErasable(@"E:\", @"C:\", @"D:\"));
    }

    [Fact]
    public void Newest_restore_point_is_never_removable()
    {
        RestorePoint P(uint s) => new(s, "rp" + s, DateTime.UtcNow);
        var all = new[] { P(10), P(12), P(11) };
        Assert.False(RestorePanel.CanRemove(all[1], all));
        Assert.True(RestorePanel.CanRemove(all[0], all));
        Assert.Equal(new DateTime(2026, 10, 22, 8, 15, 0, DateTimeKind.Utc), RestorePanel.ParseCim("20261022081500.000000-000"));
    }

    [Fact]
    public void Restore_points_list_reads_wmi_or_asks_for_admin() // read-only query of the real machine
    {
        if (!Environment.IsPrivilegedProcess)
            Assert.Throws<UnauthorizedAccessException>(() => RestorePanel.List());
        else
            Assert.All(RestorePanel.List(), p => Assert.True(p.Seq > 0 && p.Created.Year > 2000));
    }
}
