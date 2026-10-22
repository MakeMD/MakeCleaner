namespace MakeCleaner;

// The dialog half of Elevated (Core has no UI).
public static class ElevatedUi
{
    // Ask, relaunch elevated, close this copy. Returns false when not elevated and nothing happened.
    public static bool Require(IWin32Window owner, string what)
    {
        if (Elevated.IsAdmin) return true;
        if (MessageBox.Show(owner, $"{what} requires administrator rights. Restart MakeCleaner as administrator?",
                "MakeCleaner", MessageBoxButtons.OKCancel, MessageBoxIcon.Information) == DialogResult.OK
            && Elevated.RelaunchAsAdmin())
            Application.Exit();
        return false;
    }
}
