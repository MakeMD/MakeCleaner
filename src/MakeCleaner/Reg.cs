using System.ComponentModel;
using System.Diagnostics;
using System.Security;
using Microsoft.Win32;

namespace MakeCleaner;

// Registry by full path ("HKLM\SOFTWARE\..."), always the 64-bit view (32-bit keys are addressed via WOW6432Node).
// Writes go direct first; only on access-denied they repeat through an elevated reg.exe, so UAC appears at the moment of the action.
public static class Reg
{
    static (RegistryHive hive, string sub) Split(string path)
    {
        var i = path.IndexOf('\\');
        var hive = path[..i].ToUpperInvariant() switch
        {
            "HKCU" or "HKEY_CURRENT_USER" => RegistryHive.CurrentUser,
            "HKLM" or "HKEY_LOCAL_MACHINE" => RegistryHive.LocalMachine,
            "HKCR" or "HKEY_CLASSES_ROOT" => RegistryHive.ClassesRoot,
            "HKU" or "HKEY_USERS" => RegistryHive.Users,
            var h => throw new ArgumentException($"unknown hive {h}"),
        };
        return (hive, path[(i + 1)..]);
    }

    public static RegistryKey? Open(string path, bool writable = false)
    {
        var (hive, sub) = Split(path);
        return RegistryKey.OpenBaseKey(hive, RegistryView.Registry64).OpenSubKey(sub, writable);
    }

    public static string[] SubKeys(string path)
    {
        using var k = Open(path);
        return k?.GetSubKeyNames() ?? [];
    }

    public static bool SetBinary(string key, string name, byte[] value) => Elevated.Try(() =>
    {
        var (hive, sub) = Split(key);
        using var k = RegistryKey.OpenBaseKey(hive, RegistryView.Registry64).CreateSubKey(sub, true);
        k.SetValue(name, value, RegistryValueKind.Binary);
    }, "reg.exe", $"add \"{key}\" /v \"{name}\" /t REG_BINARY /d {Convert.ToHexString(value)} /f /reg:64");

    public static bool SetString(string key, string name, string value) => Elevated.Try(() =>
    {
        var (hive, sub) = Split(key);
        using var k = RegistryKey.OpenBaseKey(hive, RegistryView.Registry64).CreateSubKey(sub, true);
        k.SetValue(name, value);
    }, "reg.exe", $"add \"{key}\" /v \"{name}\" /t REG_SZ /d \"{value}\" /f /reg:64");

    public static bool DeleteValue(string key, string name) => Elevated.Try(() =>
    {
        using var k = Open(key, true);
        k?.DeleteValue(name, false);
    }, "reg.exe", $"delete \"{key}\" /v \"{name}\" /f /reg:64");

    public static bool DeleteKey(string key) => Elevated.Try(() =>
    {
        var (hive, sub) = Split(key);
        RegistryKey.OpenBaseKey(hive, RegistryView.Registry64).DeleteSubKeyTree(sub, false);
    }, "reg.exe", $"delete \"{key}\" /f /reg:64");
}

public static class Elevated
{
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
