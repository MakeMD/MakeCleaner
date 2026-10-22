using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace MakeCleaner;

// Drive Wiper logic (Tools > Drive Wiper): which drives may be erased, where to wipe, format, SSD detection.
public static class DriveWiper
{
    public static string SystemRoot => Path.GetPathRoot(Environment.SystemDirectory)!;

    // null = may be erased entirely; otherwise the reason it must not be.
    public static string? CheckErasable(string root, string systemRoot, string exeRoot)
    {
        if (string.Equals(root, systemRoot, StringComparison.OrdinalIgnoreCase)) return $"{root} is the system drive and cannot be erased entirely.";
        if (string.Equals(root, exeRoot, StringComparison.OrdinalIgnoreCase)) return $"MakeCleaner is running from {root}; it cannot erase its own drive.";
        return null;
    }

    public static bool IsSystemDrive(string root) => string.Equals(root, SystemRoot, StringComparison.OrdinalIgnoreCase);

    // The system drive root needs admin to write to; %TEMP% lives on the same volume, so wipe through it.
    public static string WipeDir(string root) =>
        string.Equals(root, Path.GetPathRoot(Path.GetTempPath()), StringComparison.OrdinalIgnoreCase) ? Path.GetTempPath() : root;

    public static void Format(DriveInfo d)
    {
        var label = d.VolumeLabel.Replace("'", "''");
        var cmd = $"$ErrorActionPreference='Stop'; Format-Volume -DriveLetter {d.Name[0]} -FileSystem {d.DriveFormat} -NewFileSystemLabel '{label}' -Force -Confirm:$false | Out-Null";
        using var p = Process.Start(new ProcessStartInfo("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", cmd])
            { CreateNoWindow = true, UseShellExecute = false })!;
        p.WaitForExit();
        if (p.ExitCode != 0) throw new IOException($"Formatting {d.Name} failed (exit {p.ExitCode}).");
    }

    // true = SSD, false = spinning disk, null = unknown (treated like SSD for the warning).
    public static bool? IsSsd(string root)
    {
        using var h = CreateFileW($@"\\.\{root[0]}:", 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h.IsInvalid) return null;
        var q = new StoragePropertyQuery { PropertyId = 7 }; // StorageDeviceSeekPenaltyProperty
        return DeviceIoControl(h, 0x2D1400, ref q, Marshal.SizeOf<StoragePropertyQuery>(), out SeekPenalty r,
            Marshal.SizeOf<SeekPenalty>(), out _, IntPtr.Zero) ? !r.IncursSeekPenalty : null;
    }

    [StructLayout(LayoutKind.Sequential)] struct StoragePropertyQuery { public int PropertyId, QueryType; public byte Extra; }
    [StructLayout(LayoutKind.Sequential)] struct SeekPenalty { public int Version, Size; [MarshalAs(UnmanagedType.U1)] public bool IncursSeekPenalty; }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, ref StoragePropertyQuery inBuf, int inSize,
        out SeekPenalty outBuf, int outSize, out int returned, IntPtr overlapped);
}
