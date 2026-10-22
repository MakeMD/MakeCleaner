using System.Diagnostics;
using MakeCleaner;
using Microsoft.Win32;

// Every test works on its own HKCU\Software\MakeCleanerTest\<guid> branch with fake HKCU/HKLM roots; nothing else is touched.
public class RegistryTests : IDisposable
{
    const string TestRoot = @"Software\MakeCleanerTest";
    readonly string branch = $@"{TestRoot}\{Guid.NewGuid():N}";
    readonly RegistryKey hkcu, hklm;
    readonly string dir = Directory.CreateTempSubdirectory("mc-reg-").FullName;
    readonly string missing, existing;

    public RegistryTests()
    {
        hkcu = Registry.CurrentUser.CreateSubKey($@"{branch}\HKCU");
        hklm = Registry.CurrentUser.CreateSubKey($@"{branch}\HKLM");
        missing = Path.Combine(dir, "nope.exe");
        existing = Path.Combine(dir, "here.exe");
        File.WriteAllText(existing, "x");
    }

    public void Dispose()
    {
        hkcu.Dispose();
        hklm.Dispose();
        Registry.CurrentUser.DeleteSubKeyTree(branch, false);
        using (var t = Registry.CurrentUser.OpenSubKey(TestRoot))
            if (t is { SubKeyCount: 0 }) Registry.CurrentUser.DeleteSubKey(TestRoot, false);
        Directory.Delete(dir, true);
    }

    RegScanner Scanner => new(hkcu, hklm);

    static void Set(RegistryKey hive, string key, string name, object data, RegistryValueKind kind = RegistryValueKind.String)
    {
        using var k = hive.CreateSubKey(key);
        k.SetValue(name, data, kind);
    }

    // One bad + one good (or out-of-scope) entry for each of the 15 categories.
    void SeedAll()
    {
        const string cv = @"SOFTWARE\Microsoft\Windows\CurrentVersion";
        Set(hklm, $@"{cv}\SharedDLLs", missing, 1, RegistryValueKind.DWord);
        Set(hklm, $@"{cv}\SharedDLLs", existing, 1, RegistryValueKind.DWord);

        Set(hkcu, @"Software\Classes\.mcbad", "", "MakeCleaner.NoSuchProgId");
        Set(hkcu, @"Software\Classes\.mcgood", "", "MakeCleaner.GoodProg");
        Set(hkcu, @"Software\Classes\MakeCleaner.GoodProg", "", "Good");

        Set(hkcu, @"Software\Classes\CLSID\{00000000-0000-0000-0000-00000000BAD1}\InprocServer32", "", missing);
        Set(hkcu, @"Software\Classes\CLSID\{00000000-0000-0000-0000-00000000600D}\InprocServer32", "", existing);

        Set(hkcu, @"Software\Classes\TypeLib\{00000000-0000-0000-0000-00000000BAD2}\1.0\0\win32", "", missing);
        Set(hkcu, @"Software\Classes\TypeLib\{00000000-0000-0000-0000-00000000600E}\1.0\0\win64", "", existing);

        Set(hkcu, @"Software\Classes\Applications\nope.exe\shell\open\command", "", $"\"{missing}\" \"%1\"");
        Set(hkcu, @"Software\Classes\Applications\here.exe\shell\open\command", "", $"\"{existing}\" \"%1\"");

        Set(hkcu, @"Software\Microsoft\Windows NT\CurrentVersion\Fonts", "Bad (TrueType)", Path.Combine(dir, "nope.ttf"));
        Set(hklm, @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts", "Bad (TrueType)", "makecleaner-nope.ttf");
        Set(hklm, @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts", "Arial (TrueType)", "arial.ttf");

        Set(hkcu, $@"{cv}\App Paths\nope.exe", "", missing);
        Set(hkcu, $@"{cv}\App Paths\here.exe", "", existing);

        Set(hklm, @"SOFTWARE\Microsoft\Windows\Help", "nope.hlp", dir);
        Set(hklm, @"SOFTWARE\Microsoft\Windows\Help", "here.exe", dir);

        Set(hklm, $@"{cv}\Installer\Folders", Path.Combine(dir, "gone") + @"\", "");
        Set(hklm, $@"{cv}\Installer\Folders", dir + @"\", "");

        Registry.CurrentUser.CreateSubKey($@"{branch}\HKCU\Software\EmptyVendor").Dispose();
        Set(hkcu, @"Software\UsedVendor", "x", "1");

        Set(hkcu, $@"{cv}\Run", "Bad", $"\"{missing}\" /min");
        Set(hkcu, $@"{cv}\Run", "Good", $"\"{existing}\" /min");
        Set(hkcu, $@"{cv}\Run", "OnPath", "notepad.exe"); // relative -> unknown -> not an issue

        Set(hkcu, $@"{cv}\Explorer\MenuOrder\Start Menu2\Programs\MakeCleanerNoSuchFolder", "Order", new byte[] { 1 }, RegistryValueKind.Binary);

        const string mui = @"Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache";
        Set(hkcu, mui, missing + ".FriendlyAppName", "Gone");
        Set(hkcu, mui, existing + ".FriendlyAppName", "Here");
        Set(hkcu, mui, "@shell32.dll,-1", "Resource"); // indirect string, ignored

        Set(hkcu, @"AppEvents\Schemes\Apps\.Default\MCBad\.Current", "", Path.Combine(dir, "nope.wav"));
        Set(hkcu, @"AppEvents\Schemes\Apps\.Default\MCGood\.Current", "", existing);
        Set(hkcu, @"AppEvents\Schemes\Apps\.Default\MCEmpty\.Current", "", "");

        const string svc = @"SYSTEM\CurrentControlSet\Services";
        Set(hklm, $@"{svc}\BadSvc", "ImagePath", $"\"{missing}\" -k", RegistryValueKind.ExpandString);
        Set(hklm, $@"{svc}\BadSvc", "Type", 0x10, RegistryValueKind.DWord);
        Set(hklm, $@"{svc}\GoodSvc", "ImagePath", existing, RegistryValueKind.ExpandString);
        Set(hklm, $@"{svc}\GoodSvc", "Type", 0x20, RegistryValueKind.DWord);
        Set(hklm, $@"{svc}\SomeDriver", "ImagePath", missing, RegistryValueKind.ExpandString);
        Set(hklm, $@"{svc}\SomeDriver", "Type", 1, RegistryValueKind.DWord); // kernel driver: never touched
    }

    [Fact]
    public void Each_category_flags_only_the_broken_entry()
    {
        SeedAll();
        var found = Scanner.Scan(RegScanner.Categories, []);
        var byCat = found.GroupBy(i => i.Category).ToDictionary(g => g.Key, g => g.Count());
        foreach (var c in RegScanner.Categories)
        {
            var expected = c.Name == "Fonts" ? 2 : 1; // one per-user + one machine-wide broken font
            Assert.True(byCat.GetValueOrDefault(c.Name) == expected,
                $"{c.Name}: expected {expected}, got {byCat.GetValueOrDefault(c.Name)}: " +
                string.Join("; ", found.Where(i => i.Category == c.Name).Select(i => i.Target)));
        }
        Assert.DoesNotContain(found, i => i.Target.Contains("here", StringComparison.OrdinalIgnoreCase));
        Assert.DoesNotContain(found, i => i.Target.Contains("Good", StringComparison.Ordinal));
        Assert.DoesNotContain(found, i => i.Target.Contains("SomeDriver"));
    }

    [Fact]
    public void Scan_changes_nothing()
    {
        SeedAll();
        string Snapshot()
        {
            var f = Path.Combine(dir, Guid.NewGuid() + ".reg");
            RegFix.WriteBackup([new RegIssue("", "", "", $@"HKEY_CURRENT_USER\{branch}", null)], f);
            return File.ReadAllText(f);
        }
        var before = Snapshot();
        Scanner.Scan(RegScanner.Categories, []);
        Assert.Equal(before, Snapshot());
    }

    [Fact]
    public void Excluded_keys_and_values_are_not_reported()
    {
        SeedAll();
        var all = Scanner.Scan(RegScanner.Categories, []);
        var run = Assert.Single(all, i => i.Category == "Run At Startup");
        var com = Assert.Single(all, i => i.Category == "ActiveX and Class Issues");

        var rest = Scanner.Scan(RegScanner.Categories, [run.Target, com.KeyPath + @"\"]);
        Assert.Equal(all.Count - 2, rest.Count);
        Assert.DoesNotContain(rest, i => i.Target == run.Target || i.Target == com.Target);
    }

    [Fact]
    public void Fix_deletes_after_backup_and_backup_restores_everything()
    {
        SeedAll();
        // give one key-level issue every value type, plus a subkey, to prove the export round-trips
        const string clsid = @"Software\Classes\CLSID\{00000000-0000-0000-0000-00000000BAD1}";
        Set(hkcu, clsid, "dw", unchecked((int)0xDEADBEEF), RegistryValueKind.DWord);
        Set(hkcu, clsid, "qw", 0x0123456789ABCDEFL, RegistryValueKind.QWord);
        Set(hkcu, clsid, "exp", @"%SystemRoot%\x", RegistryValueKind.ExpandString);
        Set(hkcu, clsid, "multi", new[] { "a", "b \"q\"" }, RegistryValueKind.MultiString);
        Set(hkcu, clsid, "bin", new byte[] { 0, 1, 255 }, RegistryValueKind.Binary);
        Set(hkcu, clsid, "none", new byte[] { 7 }, RegistryValueKind.None);
        Set(hkcu, clsid, "", "line1\r\nline2");
        Set(hkcu, clsid, @"quote""and\slash", @"C:\a ""b""");

        var issues = Scanner.Scan(RegScanner.Categories, []);
        var full = Path.Combine(dir, "full.reg");
        RegFix.WriteBackup([new RegIssue("", "", "", $@"HKEY_CURRENT_USER\{branch}", null)], full);
        var before = File.ReadAllText(full);

        var backup = Path.Combine(dir, RegFix.DefaultBackupName(DateTime.Now));
        var r = RegFix.Fix(issues, backup);
        Assert.Equal((issues.Count, 0), (r.Fixed, r.Failed));
        Assert.StartsWith("Windows Registry Editor Version 5.00", File.ReadAllText(backup));
        Assert.Empty(Scanner.Scan(RegScanner.Categories, []));
        using (var k = hkcu.OpenSubKey(clsid)) Assert.Null(k);

        var reg = Process.Start(new ProcessStartInfo("reg.exe", $"import \"{backup}\"")
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true })!;
        reg.WaitForExit();
        Assert.True(reg.ExitCode == 0, reg.StandardError.ReadToEnd());

        RegFix.WriteBackup([new RegIssue("", "", "", $@"HKEY_CURRENT_USER\{branch}", null)], full);
        Assert.Equal(Sorted(before), Sorted(File.ReadAllText(full)));
    }

    // Key order after re-import can differ; compare as sets of lines.
    static string[] Sorted(string reg) => [.. reg.Split("\r\n").Where(l => l.Length > 0).Order(StringComparer.Ordinal)];

    [Fact]
    public void Backup_failure_changes_nothing()
    {
        SeedAll();
        var issues = Scanner.Scan(RegScanner.Categories, []);
        Assert.ThrowsAny<IOException>(() => RegFix.Fix(issues, Path.Combine(dir, "no-such-dir", "b.reg")));
        Assert.Equal(issues.Count, Scanner.Scan(RegScanner.Categories, []).Count);
    }

    [Theory]
    [InlineData("\"C:\\Program Files\\App\\app.exe\" /min", "C:\\Program Files\\App\\app.exe")]
    [InlineData("C:\\Program Files\\App\\app.exe /min", "C:\\Program Files\\App\\app.exe")]
    [InlineData("C:\\Windows\\System32\\shell32.dll,-101", "C:\\Windows\\System32\\shell32.dll")]
    [InlineData("notepad.exe", null)]
    [InlineData("rundll32.exe C:\\x\\y.dll,Entry", null)]
    [InlineData("\\\\server\\share\\app.exe", null)]
    [InlineData("%MC_NO_SUCH_VAR%\\app.exe", null)]
    public void ExtractPath_is_conservative(string cmd, string? expected) =>
        Assert.Equal(expected, RegScanner.ExtractPath(cmd));

    [Fact]
    public void Unreadable_location_is_unknown_not_missing()
    {
        // non-admin cannot list %windir%\System32\config; anything below it must never be reported
        var cfg = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"config\systemprofile\makecleaner-nope.dll");
        if (Environment.IsPrivilegedProcess) return; // admin can list it: the case doesn't apply
        Assert.False(RegScanner.Missing(cfg));
        Assert.True(RegScanner.Missing(missing));
    }

    [Fact]
    public void Real_system_scan_is_read_only_and_does_not_throw()
    {
        var issues = RegScanner.ForThisPc().Scan(RegScanner.Categories, []);
        Assert.All(issues, i => Assert.False(string.IsNullOrEmpty(i.KeyPath)));
    }
}
