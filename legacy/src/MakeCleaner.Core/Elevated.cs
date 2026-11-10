using System.ComponentModel;
using System.Diagnostics;
using System.Security;

namespace MakeCleaner;

// MakeCleaner runs as the user; admin-only actions ask for UAC only when the user starts one.
public static class Elevated
{
    public static bool IsAdmin => Environment.IsPrivilegedProcess;

    // true = elevated copy started (caller should close); false = user declined UAC
    public static bool RelaunchAsAdmin()
    {
        try
        {
            Process.Start(new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = true, Verb = "runas" });
            return true;
        }
        catch (Win32Exception) { return false; }
    }

    // Runs a system tool elevated (UAC prompt only now). False if the user declined or the tool failed.
    public static bool Run(string exe, string args)
    {
        try
        {
            using var p = Process.Start(new ProcessStartInfo(exe, args)
            {
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden,
            })!;
            p.WaitForExit();
            return p.ExitCode == 0;
        }
        catch (Win32Exception) { return false; } // UAC declined
    }

    public static bool Try(Action direct, string exe, string args)
    {
        try { direct(); return true; }
        catch (Exception e) when (e is UnauthorizedAccessException or SecurityException) { return Run(exe, args); }
    }
}
