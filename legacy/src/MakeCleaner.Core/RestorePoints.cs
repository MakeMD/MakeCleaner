using System.Globalization;
using System.Runtime.InteropServices;

namespace MakeCleaner;

public record RestorePoint(uint Seq, string Description, DateTime Created);

// System Restore points: list and remove (Tools > System Restore). WMI denies both without admin.
public static class RestorePoints
{
    // The newest restore point is the user's safety net: never removable.
    public static bool CanRemove(RestorePoint p, IReadOnlyCollection<RestorePoint> all) => all.Count > 0 && p.Seq != all.Max(x => x.Seq);

    // WMI root\default:SystemRestore through WbemScripting COM (no System.Management dependency).
    public static List<RestorePoint> List()
    {
        dynamic locator = Activator.CreateInstance(Type.GetTypeFromProgID("WbemScripting.SWbemLocator")!)!;
        dynamic wmi = locator.ConnectServer(".", @"root\default");
        var result = new List<RestorePoint>();
        foreach (dynamic rp in wmi.ExecQuery("SELECT * FROM SystemRestore"))
            if (rp == null) throw new UnauthorizedAccessException("Administrator rights are required to list restore points.");
            else result.Add(new RestorePoint(Convert.ToUInt32(rp.SequenceNumber), (string)rp.Description, ParseCim((string)rp.CreationTime)));
        return result;
    }

    // CIM_DATETIME "yyyyMMddHHmmss.ffffff+UUU" (UTC for SystemRestore)
    public static DateTime ParseCim(string s) =>
        DateTime.ParseExact(s[..14], "yyyyMMddHHmmss", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);

    // 0 = removed; otherwise the Win32 error code.
    public static int Remove(uint seq) => SRRemoveRestorePoint(seq);

    [DllImport("srclient.dll")]
    static extern int SRRemoveRestorePoint(uint seq);
}
