using System.Diagnostics;
using System.Xml.Linq;
using MakeCleaner;

public class ScheduleTests : IDisposable
{
    readonly string dir = Directory.CreateTempSubdirectory("mc-sched-").FullName;

    public void Dispose() => Directory.Delete(dir, true);

    static readonly XNamespace T = "http://schemas.microsoft.com/windows/2004/02/mit/task";
    static readonly DateTime At = new(2031, 3, 5, 12, 30, 0); // a Wednesday

    [Theory]
    [InlineData(ScheduleKind.Once, "TimeTrigger")]
    [InlineData(ScheduleKind.Daily, "CalendarTrigger")]
    [InlineData(ScheduleKind.Weekly, "CalendarTrigger")]
    [InlineData(ScheduleKind.AtLogon, "LogonTrigger")]
    public void Task_xml_has_the_right_trigger_and_runs_auto(ScheduleKind kind, string trigger)
    {
        var x = XDocument.Parse(Schedule.TaskXml(kind, At, @"C:\Apps & Tools\MakeCleaner.exe", @"PC\me", shutdown: false));
        var t = Assert.Single(x.Root!.Element(T + "Triggers")!.Elements());
        Assert.Equal(trigger, t.Name.LocalName);
        if (kind != ScheduleKind.AtLogon) Assert.Equal("2031-03-05T12:30:00", t.Element(T + "StartBoundary")!.Value);
        if (kind == ScheduleKind.Weekly) Assert.NotNull(t.Descendants(T + "Wednesday").SingleOrDefault());
        if (kind == ScheduleKind.AtLogon) Assert.Equal(@"PC\me", t.Element(T + "UserId")!.Value);
        var exec = x.Descendants(T + "Exec").Single();
        Assert.Equal(@"C:\Apps & Tools\MakeCleaner.exe", exec.Element(T + "Command")!.Value); // escaped, round-trips
        Assert.Equal("/auto", exec.Element(T + "Arguments")!.Value);
        Assert.Equal("LeastPrivilege", x.Descendants(T + "RunLevel").Single().Value);
    }

    [Fact]
    public void Shutdown_is_passed_to_auto() =>
        Assert.Contains("<Arguments>/auto /shutdown</Arguments>", Schedule.TaskXml(ScheduleKind.Daily, At, @"C:\m.exe", "u", shutdown: true));

    // Registers real tasks under a throwaway name, pointing at a missing exe with a trigger years away; always deleted.
    [Fact]
    public void Task_scheduler_accepts_every_kind_and_delete_leaves_nothing()
    {
        var name = "MakeCleaner Test " + Guid.NewGuid().ToString("N");
        try
        {
            foreach (var kind in Enum.GetValues<ScheduleKind>())
            {
                Schedule.Create(kind, DateTime.Now.AddYears(5), shutdown: false, name, exe: Path.Combine(dir, "missing.exe"));
                Assert.NotNull(Schedule.Describe(name));
            }
        }
        finally { Schedule.Delete(name); }
        Assert.Null(Schedule.Describe(name));
        Schedule.Delete(name); // deleting twice is fine
    }

    // The real exe, in its own process: portable ini with only Temporary Files ticked, TEMP/AppData pointed at a fixture.
    [Fact]
    public void Auto_cleans_saved_items_without_a_window_and_logs()
    {
        var app = Path.Combine(dir, "app");
        CopyApp(AppContext.BaseDirectory, app);
        File.WriteAllText(Path.Combine(app, "portable.dat"), "#PORTABLE#");
        var names = Rule.ParseIni(Engine.BuiltInRules).Select(r => r.Name);
        // Wipe Free Space ticked on purpose: /auto must ignore it
        File.WriteAllLines(Path.Combine(app, Settings.FileName),
            ["[Options]", .. names.Select(n => $"{n}={n is "Temporary Files" or "Wipe Free Space"}"), "Custom Files and Folders=False"]);
        var temp = Directory.CreateDirectory(Path.Combine(dir, "temp")).FullName;
        var empty = Directory.CreateDirectory(Path.Combine(dir, "empty")).FullName;
        File.WriteAllText(Path.Combine(temp, "a.tmp"), "x");
        Directory.CreateDirectory(Path.Combine(temp, "sub"));
        File.WriteAllText(Path.Combine(temp, "sub", "b.tmp"), "yy");
        var keep = Path.Combine(dir, "keep.txt");
        File.WriteAllText(keep, "z");

        var psi = new ProcessStartInfo(Path.Combine(app, "MakeCleaner.exe"), "/auto") { UseShellExecute = false };
        psi.Environment["TEMP"] = psi.Environment["TMP"] = temp;
        psi.Environment["LOCALAPPDATA"] = psi.Environment["APPDATA"] = empty;
        using var p = Process.Start(psi)!;
        Assert.True(p.WaitForExit(60_000));
        Assert.Equal(0, p.ExitCode);
        Assert.Empty(Directory.EnumerateFiles(temp, "*", SearchOption.AllDirectories));
        Assert.True(File.Exists(keep));
        var log = File.ReadAllText(Path.Combine(app, Schedule.LogName));
        Assert.Contains("Analysis complete: 2 files", log);
        Assert.Contains("Cleaning complete: 2 files removed", log);
        Assert.DoesNotContain("free space", log);
    }

    // Only what the app needs to run (not the test host).
    static void CopyApp(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var f in Directory.EnumerateFiles(from).Where(f => Path.GetFileName(f) is var n
                     && (n.StartsWith("MakeCleaner.", StringComparison.Ordinal) || n.StartsWith("Microsoft.Data.Sqlite") || n.StartsWith("SQLitePCLRaw"))))
            File.Copy(f, Path.Combine(to, Path.GetFileName(f)));
        foreach (var sub in new[] { "rules", "runtimes" })
            foreach (var f in Directory.EnumerateFiles(Path.Combine(from, sub), "*", SearchOption.AllDirectories))
            {
                var dest = Path.Combine(to, Path.GetRelativePath(from, f));
                Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                File.Copy(f, dest);
            }
    }
}
