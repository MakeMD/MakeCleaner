using MakeCleaner;

// Windows tab: own rule set + SpecialKey procedures. Only temp fixtures are touched; system-wide
// procedures (clipboard, DNS, event logs) are only analyzed, never run.
public class WindowsTabTests : IDisposable
{
    readonly string dir = Directory.CreateTempSubdirectory("mc-t03-").FullName;
    static readonly List<Rule> Windows = Rule.ParseIni(Engine.BuiltInRules);

    public void Dispose() => Directory.Delete(dir, true);

    string Touch(string rel, DateTime? written = null)
    {
        var p = Path.Combine(dir, rel);
        Directory.CreateDirectory(Path.GetDirectoryName(p)!);
        File.WriteAllBytes(p, new byte[10]);
        if (written is { } w) File.SetLastWriteTimeUtc(p, w);
        return p;
    }

    [Fact]
    public void Rule_set_groups_specials_and_warnings_are_consistent()
    {
        // Edge lives in the Browsers tab (Browsers.cs), not in rules\Windows.ini.
        Assert.Equal(["Windows Explorer", "System", "Advanced"], Windows.Select(r => r.Group).Distinct());
        foreach (var k in Windows.SelectMany(r => r.SpecialKeys))
            Assert.True(Special.Files.ContainsKey(k) || Special.Actions.ContainsKey(k) || k == Special.WipeFreeSpace, k);
        foreach (var r in Windows.Where(r => r.Group == "Advanced"))
            Assert.True(!r.Default && r.Warning != null, r.Name);
        Assert.Equal(Windows.Count, Windows.Select(r => r.Name).Distinct().Count());
        Assert.Equal("TempOlderThan24h", Windows.Single(r => r.Name == "Temporary Files").AgeOption);
        Assert.Equal("RecycleBinOlderThan24h", Windows.Single(r => r.Name == "Empty Recycle Bin").AgeOption);
    }

    [Fact]
    public void Age_option_keeps_recent_files()
    {
        var old = Touch("old.tmp", DateTime.UtcNow.AddHours(-30));
        Touch("new.tmp");
        var rule = Assert.Single(Rule.ParseIni($"[T]\nFileKey1={dir}|*.tmp"));
        Assert.Equal(2, Engine.Analyze(rule).Count);
        rule.OlderThanHours = 24;
        Assert.Equal([old], Engine.Analyze(rule).Select(f => f.FullName));
    }

    // $I layout: version (8) + original size (8) + deletion FILETIME (8) + path...
    void BinItem(string bin, string id, DateTime deletedUtc, bool folder)
    {
        var meta = new byte[40];
        BitConverter.GetBytes(2L).CopyTo(meta, 0);
        BitConverter.GetBytes(deletedUtc.ToFileTimeUtc()).CopyTo(meta, 16);
        File.WriteAllBytes(Path.Combine(bin, "$I" + id), meta);
        if (folder) Touch(Path.Combine(Path.GetFileName(bin), "$R" + id, "deep", "x.bin"));
        else File.WriteAllBytes(Path.Combine(bin, "$R" + id), new byte[5]);
    }

    [Fact]
    public void Recycle_bin_lists_metadata_and_content_and_honours_deletion_age()
    {
        var bin = Directory.CreateDirectory(Path.Combine(dir, "S-1-5-21-test")).FullName;
        var now = new DateTime(2026, 10, 22, 12, 0, 0, DateTimeKind.Utc);
        BinItem(bin, "OLD.txt", now.AddDays(-3), folder: false);
        BinItem(bin, "NEW", now.AddHours(-1), folder: true);

        var all = Special.RecycleBin([bin], null, now).Select(f => f.Name).Order().ToList();
        Assert.Equal(["$INEW", "$IOLD.txt", "$ROLD.txt", "x.bin"], all);

        var old = Special.RecycleBin([bin], 24, now).Select(f => f.Name).Order().ToList();
        Assert.Equal(["$IOLD.txt", "$ROLD.txt"], old);
    }

    [Fact]
    public void Broken_shortcuts_only_for_missing_local_targets()
    {
        dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell")!)!;
        void Lnk(string name, string target)
        {
            var s = shell.CreateShortcut(Path.Combine(dir, name));
            s.TargetPath = target;
            s.Save();
        }
        var existing = Touch("real.txt");
        Lnk("ok.lnk", existing);
        Lnk("broken.lnk", Path.Combine(dir, "gone", "missing.exe"));
        Lnk("network.lnk", @"\\nonexistent-host\share\app.exe");

        Assert.Equal(["broken.lnk"], Special.BrokenShortcuts([dir]).Select(f => f.Name));
    }

    [Fact]
    public void Action_items_are_described_not_run_by_analyze()
    {
        var dns = Windows.Single(r => r.Name == "DNS Cache");
        Assert.Equal("DNS resolver cache", Assert.Single(Engine.AnalyzeActions(dns)).Label);
        var logs = Windows.Single(r => r.Name == "Windows Event Logs");
        Assert.Single(Engine.AnalyzeActions(logs));
        Assert.Empty(Engine.Analyze(dns)); // action rules add no files
    }
}
