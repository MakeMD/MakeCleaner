using MakeCleaner;
using Microsoft.Win32;

public class Winapp2Tests : IDisposable
{
    readonly string dir = Directory.CreateTempSubdirectory("mc-w2-").FullName;
    readonly string regRoot = @"Software\MakeCleanerTest\" + Guid.NewGuid().ToString("N");
    string Hkcu => @"HKCU\" + regRoot;

    public void Dispose()
    {
        Directory.Delete(dir, true);
        Registry.CurrentUser.DeleteSubKeyTree(regRoot, false);
    }

    string Touch(string rel, int bytes = 10)
    {
        var p = Path.Combine(dir, rel);
        Directory.CreateDirectory(Path.GetDirectoryName(p)!);
        File.WriteAllBytes(p, new byte[bytes]);
        return p;
    }

    static Rule One(string ini) => Assert.Single(Rule.ParseIni(ini));

    static List<string> Names(IEnumerable<FileInfo> fs) => [.. fs.Select(f => f.Name).Order()];

    [Fact]
    public void Keys_are_case_insensitive_and_numbered()
    {
        var r = One("""
            [App *]
            langsecref=3023
            DEFAULT=true
            Warning=Careful
            detect1=HKCU\Software\A
            Detect2=HKCU\Software\B
            DETECTFILE=%AppData%\A
            SpecialDetect=DET_CHROME
            DetectOS=6.1|
            filekey1=C:\x|*.log|RECURSE
            FILEKEY12=C:\y|*|REMOVESELF
            regkey1=HKCU\Software\A|Val
            ExcludeKey1=FILE|C:\x\|keep.log
            """);
        Assert.Equal(("App *", "Multimedia", true, "Careful", "6.1|"), (r.Name, r.Group, r.Default, r.Warning, r.DetectOS));
        Assert.Equal(2, r.Detect.Count);
        Assert.Single(r.DetectFile);
        Assert.Single(r.SpecialDetect);
        Assert.Equal([true, true], r.FileKeys.Select(k => k.Recurse));
        Assert.Equal([false, true], r.FileKeys.Select(k => k.RemoveSelf));
        Assert.Equal(new RegKey(@"HKCU\Software\A", "Val"), Assert.Single(r.RegKeys));
        Assert.Equal(("FILE", @"C:\x\", "keep.log"), (r.Excludes[0].Kind, r.Excludes[0].Path, r.Excludes[0].Patterns[0]));
        Assert.Equal("Games", One("[G]\nSection=Games\nLangSecRef=3021").Group);
        Assert.False(One("[N]").Default);
    }

    [Fact]
    public void Recurse_removeself_and_top_level_only()
    {
        Touch(@"plain\a.log"); Touch(@"plain\sub\b.log");
        Touch(@"rec\a.log"); Touch(@"rec\sub\b.log");
        Touch(@"self\a.log"); Touch(@"self\sub\b.log");
        var r = One($"[T]\nFileKey1={dir}\\plain|*.log\nFileKey2={dir}\\rec|*.log|RECURSE\nFileKey3={dir}\\self|*|REMOVESELF");

        var found = Engine.Analyze(r);
        Assert.Equal(5, found.Count); // plain\sub\b.log is not reached
        Engine.Clean(found);
        Engine.RemoveEmptyDirs(r);

        Assert.True(File.Exists(Path.Combine(dir, @"plain\sub\b.log")));
        Assert.True(Directory.Exists(Path.Combine(dir, @"rec\sub"))); // RECURSE keeps folders
        Assert.False(Directory.Exists(Path.Combine(dir, "self")));   // REMOVESELF drops the folder itself
    }

    [Fact]
    public void Removeself_keeps_folder_with_leftovers()
    {
        Touch(@"self\a.log");
        Touch(@"self\keep.txt");
        var r = One($"[T]\nFileKey1={dir}\\self|*.log|REMOVESELF");
        Engine.Clean(Engine.Analyze(r));
        Engine.RemoveEmptyDirs(r);
        Assert.True(File.Exists(Path.Combine(dir, @"self\keep.txt")));
    }

    [Fact]
    public void Wildcards_in_path_segments()
    {
        Touch(@"Packages\AppA_1\AC\Temp\x.tmp");
        Touch(@"Packages\AppB_2\AC\Temp\y.tmp");
        Touch(@"Packages\Other\AC\Temp\z.tmp");
        var r = One($"[T]\nFileKey1={dir}\\Packages\\App*\\AC\\Temp|*.tmp");
        Assert.Equal(["x.tmp", "y.tmp"], Names(Engine.Analyze(r)));
    }

    [Fact]
    public void ExcludeKey_file_and_path_protect_matches()
    {
        Touch(@"c\keep.log"); Touch(@"c\gone.log");
        Touch(@"c\sub\gone2.log"); Touch(@"c\db\a.db"); Touch(@"c\db\b.log");
        var r = One($"""
            [T]
            FileKey1={dir}\c|*|RECURSE
            ExcludeKey1=FILE|{dir}\c\|keep.log
            ExcludeKey2=PATH|{dir}\c\db\|*.db
            """);
        Assert.Equal(["b.log", "gone.log", "gone2.log"], Names(Engine.Analyze(r)));
    }

    [Fact]
    public void RegKey_deletes_key_or_value_and_ExcludeKey_reg_protects()
    {
        using (var k = Registry.CurrentUser.CreateSubKey(regRoot + @"\Gone"))
            k.SetValue("x", 1);
        using (var k = Registry.CurrentUser.CreateSubKey(regRoot + @"\Vals"))
        {
            k.SetValue("drop", "1");
            k.SetValue("stay", "1");
        }
        Registry.CurrentUser.CreateSubKey(regRoot + @"\Kept\Child").Dispose();
        var r = One($"""
            [T]
            RegKey1={Hkcu}\Gone
            RegKey2={Hkcu}\Vals|drop
            RegKey3={Hkcu}\Kept\Child
            RegKey4={Hkcu}\Missing
            ExcludeKey1=REG|{Hkcu}\Kept
            """);

        var targets = Engine.AnalyzeRegistry(r);
        Assert.Equal(2, targets.Count); // Missing doesn't exist, Kept is excluded
        Assert.Equal(2, Engine.CleanRegistry(targets).Deleted);

        Assert.Null(Registry.CurrentUser.OpenSubKey(regRoot + @"\Gone"));
        using var vals = Registry.CurrentUser.OpenSubKey(regRoot + @"\Vals")!;
        Assert.Equal(["stay"], vals.GetValueNames());
        Assert.NotNull(Registry.CurrentUser.OpenSubKey(regRoot + @"\Kept\Child"));
    }

    [Fact]
    public void Top_level_hive_keys_are_never_deleted()
    {
        Assert.False(Reg.Delete(new RegKey(@"HKCU\Software", null)));
        Assert.False(Reg.Delete(new RegKey("HKCU", null)));
        Assert.NotNull(Registry.CurrentUser.OpenSubKey("Software"));
    }

    [Fact]
    public void Detection_by_registry_file_wildcard_and_os()
    {
        Registry.CurrentUser.CreateSubKey(regRoot + @"\Installed").Dispose();
        Touch(@"Vendor\Product 2024\app.exe");
        Assert.True(One("[T]").IsDetected()); // no detection keys = always shown
        Assert.True(One($"[T]\nDetect1=HKCU\\Software\\NoSuchKey_mc\nDetect2={Hkcu}\\Installed").IsDetected());
        Assert.False(One($"[T]\nDetect={Hkcu}\\NotInstalled").IsDetected());
        Assert.True(One($"[T]\nDetectFile={dir}\\Vendor\\Product*").IsDetected());
        Assert.True(One($"[T]\nDetectFile={dir}\\Vendor\\*\\app.exe").IsDetected());
        Assert.False(One($"[T]\nDetectFile={dir}\\Vendor\\Nope*").IsDetected());
        Assert.False(One("[T]\nSpecialDetect=DET_UNKNOWN").IsDetected());
        Assert.False(One($"[T]\nDetectOS=99.0|\nDetect={Hkcu}\\Installed").IsDetected()); // OS gate wins
    }

    [Theory]
    [InlineData("6.1|", true)]
    [InlineData("|6.3", false)]
    [InlineData("10.0|10.0", true)]
    [InlineData("10.0.21996|", true)]
    [InlineData("10.0.30000|", false)]
    [InlineData("|10.0.21995", false)]
    public void DetectOS_min_max(string range, bool expected) =>
        Assert.Equal(expected, Paths.OsInRange(range, new Version(10, 0, 26300)));

    [Fact]
    public void ProgramFiles_expands_to_both_folders_and_unknown_var_to_nothing()
    {
        var pf = Paths.ExpandVars(@"%ProgramFiles%\X").ToList();
        Assert.Equal(2, pf.Count);
        Assert.Contains(pf, p => p.Contains("(x86)"));
        Assert.Empty(Paths.ExpandVars(@"%MC_NO_SUCH_VAR%\X"));
        Assert.EndsWith(@"AppData\LocalLow\X", Assert.Single(Paths.ExpandVars(@"%LocalLowAppData%\X")));
    }

    [Fact]
    public void Drive_root_is_never_swept_recursively()
    {
        var root = Path.GetPathRoot(dir)!.TrimEnd('\\');
        Assert.Empty(Engine.Analyze(One($"[T]\nFileKey1={root}|*.mc_none_|RECURSE")));
    }

    [Fact]
    public void Bundled_winapp2_parses_completely()
    {
        var rules = Rule.ParseIni(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "rules", "Winapp2.ini")));
        Assert.True(rules.Count > 4000, $"only {rules.Count} entries");
        Assert.All(rules, r => Assert.True(r.FileKeys.Count + r.RegKeys.Count > 0, r.Name));
        Assert.Contains(rules, r => r.Warning != null);
        Assert.Contains(rules, r => r.FileKeys.Any(k => k.RemoveSelf));
    }

    [Fact]
    public void User_winapp2_next_to_exe_is_picked_up_and_overrides()
    {
        Directory.CreateDirectory(Path.Combine(dir, "rules"));
        File.WriteAllText(Path.Combine(dir, "rules", "Winapp2.ini"), "[Shared]\nWarning=bundled\nFileKey1=C:\\a|*\n[Bundled only]\nDetect=HKCU\\Software\\NoSuchKey_mc\nFileKey1=C:\\a|*");
        File.WriteAllText(Path.Combine(dir, "winapp2.ini"), "[Shared]\nWarning=user\nFileKey1=C:\\a|*\n[Mine]\nFileKey1=C:\\b|*");
        var rules = Rule.LoadApplications(dir);
        Assert.Equal(["Mine", "Shared"], rules.Select(r => r.Name).Order()); // undetected bundled entry hidden
        Assert.Equal("user", rules.Single(r => r.Name == "Shared").Warning);
    }
}
