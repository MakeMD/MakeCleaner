using System.Diagnostics;
using System.Security;
using System.Security.Principal;

namespace MakeCleaner;

public enum ScheduleKind { Once, Daily, Weekly, AtLogon }

// "MakeCleaner.exe /auto": the GUI's saved ticks, no window, no dialogs. The only way MakeCleaner ever runs on its own
// is a Task Scheduler task the user creates in Options (one task, deleted completely by Remove; no services or Run keys).
public static class Schedule
{
    public const string TaskName = "MakeCleaner Auto Clean";
    public const string LogName = "MakeCleaner-auto.log";

    // 0 = cleaned (files in use are skipped, not an error), 1 = failed. Never wipes free space, never touches a running browser.
    public static int Auto(Settings settings, bool shutdown)
    {
        var log = Path.Combine(Path.GetDirectoryName(settings.Path)!, LogName);
        try
        {
            var pass = new CleanPass(settings);
            var (rules, items) = CleanPass.Saved(settings);
            pass.Analyze(rules, items);
            var skip = pass.RunningBrowsers().Select(b => b.Name).ToHashSet();
            var analyzed = pass.AnalyzeSummary();
            var cleaned = pass.Clean(skip);
            Log(log, $"{analyzed} | {cleaned}");
            // ponytail: 60 s grace so the user can still run "shutdown /a"
            if (shutdown) Process.Start(new ProcessStartInfo("shutdown.exe", "/s /t 60 /c \"MakeCleaner: scheduled cleaning finished\"") { UseShellExecute = false, CreateNoWindow = true });
            return 0;
        }
        catch (Exception e)
        {
            try { Log(log, "FAILED: " + e); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            return 1;
        }
    }

    static void Log(string path, string line)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.AppendAllText(path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} /auto: {line}{Environment.NewLine}");
    }

    // Task Scheduler 1.2 XML: locale-independent, unlike schtasks /SD /ST.
    public static string TaskXml(ScheduleKind kind, DateTime at, string exe, string user, bool shutdown)
    {
        string E(string s) => SecurityElement.Escape(s);
        var start = $"<StartBoundary>{at:yyyy-MM-ddTHH:mm:ss}</StartBoundary>";
        var trigger = kind switch
        {
            ScheduleKind.Once => $"<TimeTrigger>{start}</TimeTrigger>",
            ScheduleKind.Daily => $"<CalendarTrigger>{start}<ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>",
            ScheduleKind.Weekly => $"<CalendarTrigger>{start}<ScheduleByWeek><DaysOfWeek><{at.DayOfWeek} /></DaysOfWeek><WeeksInterval>1</WeeksInterval></ScheduleByWeek></CalendarTrigger>",
            _ => $"<LogonTrigger><UserId>{E(user)}</UserId></LogonTrigger>",
        };
        return $"""
            <?xml version="1.0" encoding="UTF-16"?>
            <Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
              <RegistrationInfo><Description>MakeCleaner: cleans the items ticked in MakeCleaner (MakeCleaner.exe /auto).</Description></RegistrationInfo>
              <Triggers>{trigger}</Triggers>
              <Principals><Principal id="Author"><UserId>{E(user)}</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
              <Settings>
                <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
                <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
                <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
                <StartWhenAvailable>true</StartWhenAvailable>
                <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
              </Settings>
              <Actions Context="Author"><Exec><Command>{E(exe)}</Command><Arguments>/auto{(shutdown ? " /shutdown" : "")}</Arguments><WorkingDirectory>{E(Path.GetDirectoryName(exe)!)}</WorkingDirectory></Exec></Actions>
            </Task>
            """;
    }

    static dynamic Root()
    {
        dynamic svc = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service")!)!;
        svc.Connect();
        return svc.GetFolder(@"\");
    }

    // TASK_CREATE_OR_UPDATE = 6, TASK_LOGON_INTERACTIVE_TOKEN = 3: runs as the current user, only while signed in, no password stored.
    public static void Create(ScheduleKind kind, DateTime at, bool shutdown, string name = TaskName, string? exe = null) =>
        Root().RegisterTask(name, TaskXml(kind, at, exe ?? Environment.ProcessPath!, WindowsIdentity.GetCurrent().Name, shutdown),
            6, Type.Missing, Type.Missing, 3, Type.Missing);

    // "not found" arrives as FileNotFoundException through dynamic COM, so match the HRESULT, not the type
    static bool NotFound(Exception e) => e.HResult == unchecked((int)0x80070002);

    public static void Delete(string name = TaskName)
    {
        try { Root().DeleteTask(name, 0); }
        catch (Exception e) when (NotFound(e)) { } // already gone
    }

    // null = no task. Otherwise a one-line description for Options.
    public static string? Describe(string name = TaskName)
    {
        try
        {
            dynamic t = Root().GetTask(name);
            DateTime next = t.NextRunTime;
            return next.Year > 1900 ? $"Scheduled cleaning is on. Next run: {next:yyyy-MM-dd HH:mm}" : "Scheduled cleaning is on (runs at sign-in).";
        }
        catch (Exception e) when (NotFound(e)) { return null; }
    }
}
