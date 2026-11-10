using System.Reflection;
using MakeCleaner;

public class EngineTests : IDisposable
{
    readonly string dir = Directory.CreateTempSubdirectory("mc-test-").FullName;

    public void Dispose() => Directory.Delete(dir, true);

    string Touch(string rel, int bytes = 10)
    {
        var p = Path.Combine(dir, rel);
        Directory.CreateDirectory(Path.GetDirectoryName(p)!);
        File.WriteAllBytes(p, new byte[bytes]);
        return p;
    }

    static Rule One(string ini) => Assert.Single(Rule.ParseIni(ini));

    [Fact]
    public void Mask_deletes_only_matches()
    {
        var a = Touch("a.log");
        var keep = Touch("b.txt");
        var deep = Touch(@"sub\c.log");
        var rule = One($"[T]\nfilekey1={dir}|*.log|RECURSE");

        var found = Engine.Analyze(rule);
        Assert.Equal(2, found.Count);
        Assert.True(File.Exists(a)); // analyze never deletes

        var r = Engine.Clean(found);
        Assert.Equal((2, 20L, 0), (r.Deleted, r.BytesFreed, r.Skipped));
        Assert.False(File.Exists(a));
        Assert.False(File.Exists(deep));
        Assert.True(File.Exists(keep));
    }

    [Fact]
    public void Without_recurse_top_level_only_and_multi_pattern()
    {
        Touch("a.log");
        Touch("b.tmp");
        Touch("c.txt");
        Touch(@"sub\d.log");
        var rule = One($"[T]\nFileKey1={dir}|*.log;*.tmp");
        Assert.Equal(["a.log", "b.tmp"], Engine.Analyze(rule).Select(f => f.Name).Order());
    }

    [Fact]
    public void Env_vars_expand_and_unknown_ones_match_nothing()
    {
        Touch("x.tmp");
        Environment.SetEnvironmentVariable("MC_TEST_DIR", dir);
        Assert.Single(Engine.Analyze(One("[T]\nFileKey1=%MC_TEST_DIR%|*.tmp")));
        Assert.Empty(Engine.Analyze(One("[T]\nFileKey1=%MC_NO_SUCH_VAR%|*.*|RECURSE")));
    }

    [Fact]
    public void Locked_file_is_skipped_not_thrown()
    {
        var locked = Touch("locked.log");
        Touch("free.log");
        var found = Engine.Analyze(One($"[T]\nFileKey1={dir}|*.log"));
        using (new FileStream(locked, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            var r = Engine.Clean(found);
            Assert.Equal((1, 1), (r.Deleted, r.Skipped));
        }
        Assert.True(File.Exists(locked));
    }

    [Fact]
    public void Pass_summarizes_per_item_reports_progress_and_cancel_leaves_nothing()
    {
        Touch("a.log", 5); Touch("b.log", 7); Touch("c.tmp", 3);
        var rules = Rule.ParseIni($"[Logs]\nFileKey1={dir}|*.log\n[All]\nFileKey1={dir}|*.*\n[Empty]\nFileKey1={dir}|*.none");
        var pass = new CleanPass(new Settings(Path.Combine(dir, "cfg")));
        var steps = new List<(int, int)>();
        pass.Analyze(rules, [], new SyncProgress<(int, int)>(steps.Add));

        Assert.Equal([("Logs", 2, 12L), ("All", 1, 3L)], pass.Summary.Select(r => (r.Name, r.Items, r.Bytes))); // shared files count once
        Assert.Equal([(0, 3), (1, 3), (2, 3), (3, 3)], steps);
        Assert.Equal(3, pass.Files.Count);

        using var cts = new CancellationTokenSource();
        cts.Cancel();
        Assert.Throws<OperationCanceledException>(() => pass.Analyze(rules, [], ct: cts.Token));
        Assert.False(pass.Any); // a cancelled run never leaves the previous results armed for Clean
        Assert.Empty(pass.Summary);
    }

    // Progress<T> posts to a sync context; tests want the calls in order, right away.
    sealed class SyncProgress<T>(Action<T> report) : IProgress<T> { public void Report(T value) => report(value); }

    [Fact]
    public void Builtin_temp_rule_targets_temp_recursively()
    {
        var key = Assert.Single(Rule.ParseIni(Engine.BuiltInRules).Single(r => r.Name == "Temporary Files").FileKeys);
        Assert.Equal(("%TEMP%", true), (key.Path, key.Recurse));
    }

    [Fact]
    public void Portable_dat_keeps_settings_next_to_exe()
    {
        var appData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MakeCleaner");
        Assert.Equal(appData, Settings.ResolveDir(dir));

        File.WriteAllText(Path.Combine(dir, "portable.dat"), "#PORTABLE#");
        Assert.Equal(dir, Settings.ResolveDir(dir));

        var s = new Settings(dir);
        s.Set("Temporary Files", false);
        s.Save();
        Assert.False(new Settings(dir).GetBool("Temporary Files", true));
        Assert.True(File.Exists(Path.Combine(dir, Settings.FileName)));
    }

    // The app's build folder (the test project builds it but does not reference it).
    internal static readonly string AppDir = typeof(EngineTests).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>().Single(a => a.Key == "AppDir").Value!;

    // Assembly references read from metadata only, so nothing gets loaded into the test process.
    static string[] References(string dll)
    {
        using var pe = new System.Reflection.PortableExecutable.PEReader(File.OpenRead(dll));
        var md = System.Reflection.Metadata.PEReaderExtensions.GetMetadataReader(pe);
        return [.. md.AssemblyReferences.Select(h => md.GetString(md.GetAssemblyReference(h).Name))];
    }

    [Fact]
    public void No_shipped_assembly_references_networking()
    {
        // Walk the app's own dll and every app-local dependency it pulls in (MakeCleaner.Core, Microsoft.Data.Sqlite,
        // SQLitePCLRaw ...): exactly the managed set that ships next to / inside the published exe. Framework assemblies
        // (WPF's PresentationFramework etc.) live elsewhere and are not walked.
        var queue = new Queue<string>([Path.Combine(AppDir, "MakeCleaner.dll")]);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        while (queue.TryDequeue(out var path))
        {
            if (!seen.Add(path)) continue;
            foreach (var r in References(path))
            {
                Assert.False(r.StartsWith("System.Net", StringComparison.OrdinalIgnoreCase), $"{Path.GetFileName(path)} references {r}");
                var local = Path.Combine(AppDir, r + ".dll");
                if (File.Exists(local)) queue.Enqueue(local);
            }
        }
        Assert.Contains(seen, p => p.EndsWith("MakeCleaner.Core.dll", StringComparison.OrdinalIgnoreCase));
        Assert.Contains(seen, p => p.EndsWith("Microsoft.Data.Sqlite.dll", StringComparison.OrdinalIgnoreCase));
        Assert.Contains(seen, p => p.EndsWith("SQLitePCLRaw.core.dll", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void Core_has_no_ui_framework()
    {
        static bool Ui(string r) => r.StartsWith("System.Windows.Forms", StringComparison.OrdinalIgnoreCase)
            || r is "PresentationFramework" or "PresentationCore" or "WindowsBase" or "System.Xaml";
        Assert.DoesNotContain(References(typeof(Engine).Assembly.Location), Ui);
        Assert.Contains(References(Path.Combine(AppDir, "MakeCleaner.dll")), Ui); // the check itself sees UI references
    }
}
