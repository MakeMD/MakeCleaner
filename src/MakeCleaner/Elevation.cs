using System.Diagnostics;

namespace MakeCleaner;

// MakeCleaner runs as the user; admin-only actions ask for UAC only when the user starts one.
public static class Elevation
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
        catch (System.ComponentModel.Win32Exception) { return false; }
    }

    // Ask, relaunch elevated, close this copy. Returns false when not elevated and nothing happened.
    public static bool Require(IWin32Window owner, string what)
    {
        if (IsAdmin) return true;
        if (MessageBox.Show(owner, $"{what} requires administrator rights. Restart MakeCleaner as administrator?",
                "MakeCleaner", MessageBoxButtons.OKCancel, MessageBoxIcon.Information) == DialogResult.OK
            && RelaunchAsAdmin())
            Application.Exit();
        return false;
    }
}
