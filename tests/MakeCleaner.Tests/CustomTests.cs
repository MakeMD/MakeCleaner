using MakeCleaner;
using Microsoft.Win32;

// Options > Include / Exclude and saved checkbox states. Temp folders and HKCU\Software\MakeCleanerTest only.
public class CustomTests : IDisposable
{
    readonly string dir = Directory.CreateTempSubdirectory("mc-t04-").FullName;
    readonly string ini = Directory.CreateTempSubdirectory("mc-t04-ini-").FullName;
    readonly string sub = $@"Software\MakeCleanerTest\t04-{Guid.NewGuid():N}";

    public void Dispose()
    {
        Directory.Delete(dir, true);
        Directory.Delete(ini, true);
        Registry.CurrentUser.DeleteSubKeyTree(sub, false);
        using (var t = Registry.CurrentUser.OpenSubKey(@"Software\MakeCleanerTest", true))
            if (t != null && t.SubKeyCount == 0 && t.ValueCount == 0) Registry.CurrentUser.DeleteSubKey(@"Software\MakeCleanerTest", false);
    }

    string Touch(string rel, int ageHours = 0)
    {
        var p = Path.Combine(dir, rel);
        Directory.CreateDirectory(Path.GetDirectoryName(p)!);
        File.WriteAllBytes(p, new byte[10]);
        File.SetLastWriteTimeUtc(p, DateTime.UtcNow.AddHours(-ageHours));
        return p;
    }

    Settings With(string prefix, params string[] entries)
    {
        var s = new Settings(ini);
        s.SetList(prefix, entries);
        return s;
    }

    static string[] Names(IEnumerable<FileInfo> files) => [.. files.Select(f => f.Name).Order()];

    [Fact]
    public void Include_modes_and_age_go_through_the_engine()
    {
        Touch("top.log", 48);
        Touch("new.log");
        Touch(@"sub\deep.log", 48);

        Assert.Equal(["new.log", "top.log"], Names(Engine.Analyze(Custom.IncludeRule(With("Include", $"{dir}|*.log")))));
        Assert.Equal(["deep.log", "new.log", "top.log"], Names(Engine.Analyze(Custom.IncludeRule(With("Include", $"{dir}|*.*|RECURSE")))));
        Assert.Equal(["deep.log", "top.log"], Names(Engine.Analyze(Custom.IncludeRule(With("Include", $"{dir}|*.*|RECURSE|OLDER=24")))));
        Assert.Equal(["new.log"], Names(Engine.Analyze(Custom.IncludeRule(With("Include", $"{dir}|new.log"))))); // single file

        var removeSelf = Custom.IncludeRule(With("Include", $@"{dir}\sub|*.*|REMOVESELF"));
        Engine.Clean(Engine.Analyze(removeSelf));
        Engine.RemoveEmptyDirs(removeSelf);
        Assert.False(Directory.Exists(Path.Combine(dir, "sub")));
    }

    [Fact]
    public void System_paths_are_rejected_and_never_loaded()
    {
        string F(Environment.SpecialFolder f) => Environment.GetFolderPath(f);
        foreach (var bad in new[] { @"C:\", "C:", @"D:\", F(Environment.SpecialFolder.Windows), @"%windir%\Temp",
                     F(Environment.SpecialFolder.ProgramFiles), F(Environment.SpecialFolder.CommonApplicationData),
                     F(Environment.SpecialFolder.UserProfile), Path.GetDirectoryName(F(Environment.SpecialFolder.UserProfile))!,
                     "relative\\dir", @"\\server\share" })
            Assert.NotNull(Custom.Reject(bad));
        Assert.Null(Custom.Reject(dir));
        Assert.Null(Custom.Reject(Path.Combine(F(Environment.SpecialFolder.UserProfile), "Downloads")));

        // a hand-edited ini cannot smuggle C:\ in
        Assert.Single(Custom.IncludeRule(With("Include", @"C:\|*.*|RECURSE", $"{dir}|*.*")).FileKeys);
    }

    [Fact]
    public void Exclude_hides_files_from_every_rule()
    {
        Touch("keep.log");
        Touch("gone.log");
        Touch(@"private\secret.log");
        var winapp2Style = Assert.Single(Rule.ParseIni($"[Some App]\nFileKey1={dir}|*.log|RECURSE"));
        var include = Custom.IncludeRule(With("Include", $"{dir}|*.*|RECURSE"));
        var s = With("Exclude", $@"PATH|{dir}\private", $"FILE|{dir}|keep.log");
        var ex = Custom.Excludes(s);

        Assert.Equal(["gone.log"], Names(Engine.Analyze(winapp2Style, ex)));
        Assert.Equal(["gone.log"], Names(Engine.Analyze(include, ex)));
        Assert.Equal(3, Engine.Analyze(winapp2Style).Count); // without the list nothing is hidden
    }

    [Fact]
    public void Registry_exclude_is_shared_by_rules_and_registry_cleaner()
    {
        using (var k = Registry.CurrentUser.CreateSubKey(sub)) k.SetValue("v", 1);
        using (Registry.CurrentUser.CreateSubKey(sub + @"\child")) { }
        var rule = Assert.Single(Rule.ParseIni($"[R]\nRegKey1=HKCU\\{sub}|v\nRegKey2=HKCU\\{sub}\\child"));
        var s = With("Exclude", $@"REG|HKCU\{sub}\child");
        Custom.AddExclude(s, $@"REG|HKCU\{sub}|v");

        Assert.Equal(2, Engine.AnalyzeRegistry(rule).Count);
        Assert.Empty(Engine.AnalyzeRegistry(rule, Custom.Excludes(s)));
        Assert.Equal([$@"HKCU\{sub}\child", $@"HKCU\{sub}\v"], Custom.RegistryExcludes(s));
    }

    [Fact]
    public void Lists_and_checkbox_states_survive_a_restart()
    {
        var s = new Settings(ini);
        s.SetList("Include", ["a|*.*", "b|*.*", "c|*.*"]);
        s.SetList("Include", ["b|*.*"]); // shrinking must drop Include2/Include3
        s.Set("Temporary Files", false);
        s.Set(Custom.RuleName, true);
        s.Save();

        var again = new Settings(ini);
        Assert.Equal(["b|*.*"], again.GetList("Include"));
        Assert.False(again.GetBool("Temporary Files", true));
        Assert.True(again.GetBool(Custom.RuleName, false));
    }
}
