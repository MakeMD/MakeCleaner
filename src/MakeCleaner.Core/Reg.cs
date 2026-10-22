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

    static (RegistryHive hive, string sub)? TrySplit(string key)
    {
        var cut = key.IndexOf('\\');
        var root = (cut < 0 ? key : key[..cut]).ToUpperInvariant();
        var sub = cut < 0 ? "" : key[(cut + 1)..].TrimEnd('\\');
        RegistryHive? hive = root switch
        {
            "HKCU" or "HKEY_CURRENT_USER" => RegistryHive.CurrentUser,
            "HKLM" or "HKEY_LOCAL_MACHINE" => RegistryHive.LocalMachine,
            "HKCR" or "HKEY_CLASSES_ROOT" => RegistryHive.ClassesRoot,
            "HKU" or "HKEY_USERS" => RegistryHive.Users,
            _ => null,
        };
        return hive == null || sub.Length == 0 ? null : (hive.Value, sub); // never a whole hive
    }

    // Non-throwing variant for rule detection/cleaning: null on missing key, bad hive or access denied.
    static RegistryKey? TryOpen(string key, bool writable = false, RegistryView view = RegistryView.Default)
    {
        if (TrySplit(key) is not var (hive, sub)) return null;
        try { return RegistryKey.OpenBaseKey(hive, view).OpenSubKey(sub, writable); }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException) { return null; }
    }

    // Detect checks both views: 32-bit apps live under WOW6432Node.
    public static bool KeyExists(string key)
    {
        foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
            using (var k = TryOpen(key, false, view))
                if (k != null) return true;
        return false;
    }

    public static bool Exists(RegKey t)
    {
        using var k = TryOpen(t.Key);
        return k != null && (t.Value == null || k.GetValueNames().Contains(t.Value, StringComparer.OrdinalIgnoreCase));
    }

    public static bool Delete(RegKey t)
    {
        try
        {
            if (t.Value != null)
            {
                using var k = TryOpen(t.Key, writable: true);
                if (k == null) return false;
                k.DeleteValue(t.Value, throwOnMissingValue: false);
                return true;
            }
            var cut = t.Key.LastIndexOf('\\');
            if (cut < 0) return false;
            using var parent = TryOpen(t.Key[..cut], writable: true); // null for a bare hive: top-level keys are never deleted
            if (parent == null) return false;
            parent.DeleteSubKeyTree(t.Key[(cut + 1)..], throwOnMissingSubKey: false);
            return true;
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException or ArgumentException) { return false; }
    }
}
