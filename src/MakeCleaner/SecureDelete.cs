using System.Security.Cryptography;

namespace MakeCleaner;

// Overwrite-before-delete and free-space wiping. Pass patterns (null = random bytes):
//   1 pass   zeros
//   3 passes DoD 5220.22-M: 0x00, 0xFF, random
//   7 passes DoD 5220.22-M ECE: 0x00, 0xFF, random, random, 0x00, 0xFF, random
//   35 passes Gutmann: 4 random, 27 fixed MFM/RLL patterns, 4 random
// ponytail: in-place overwrite only. SSD wear-levelling, NTFS compressed/sparse files, VSS snapshots
// and MFT-resident tiny files can keep old copies; MFT free space and cluster tips are not wiped.
public static class SecureDelete
{
    public static readonly (int Passes, string Label)[] Methods =
    [
        (0, "Normal file deletion (faster)"),
        (1, "Secure: 1 pass (zeros)"),
        (3, "Secure: 3 passes (DoD 5220.22-M)"),
        (7, "Secure: 7 passes (DoD 5220.22-M ECE)"),
        (35, "Secure: 35 passes (Gutmann)"),
    ];

    const int BufSize = 3 << 18; // 768 KB: multiple of 3 (3-byte Gutmann patterns stay in phase) and of 4 KB
    const long FileCap = 1L << 30; // wipe fill files stay under the FAT32 4 GB limit
    public const string WipeDirPrefix = "MakeCleanerWipe.";

    public static byte[]?[] Patterns(int passes)
    {
        byte[] B(params int[] v) => [.. v.Select(x => (byte)x)];
        return passes switch
        {
            1 => [B(0x00)],
            3 => [B(0x00), B(0xFF), null],
            7 => [B(0x00), B(0xFF), null, null, B(0x00), B(0xFF), null],
            35 =>
            [
                null, null, null, null,
                B(0x55), B(0xAA), B(0x92, 0x49, 0x24), B(0x49, 0x24, 0x92), B(0x24, 0x92, 0x49),
                B(0x00), B(0x11), B(0x22), B(0x33), B(0x44), B(0x55), B(0x66), B(0x77),
                B(0x88), B(0x99), B(0xAA), B(0xBB), B(0xCC), B(0xDD), B(0xEE), B(0xFF),
                B(0x92, 0x49, 0x24), B(0x49, 0x24, 0x92), B(0x24, 0x92, 0x49),
                B(0x6D, 0xB6, 0xDB), B(0xB6, 0xDB, 0x6D), B(0xDB, 0x6D, 0xB6),
                null, null, null, null,
            ],
            _ => throw new ArgumentOutOfRangeException(nameof(passes), passes, "1, 3, 7 or 35"),
        };
    }

    // passes = 0 -> plain delete. Otherwise overwrite every byte, scrub name and size, then unlink.
    public static void Delete(string path, int passes)
    {
        if (passes > 0)
        {
            Overwrite(path, passes);
            var tmp = Path.Combine(Path.GetDirectoryName(path)!, Path.GetRandomFileName());
            File.Move(path, tmp);
            using (new FileStream(tmp, FileMode.Truncate)) { }
            path = tmp;
        }
        File.Delete(path);
    }

    public static void Overwrite(string path, int passes)
    {
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.None, 1);
        var buf = new byte[BufSize];
        var len = fs.Length;
        foreach (var p in Patterns(passes)) Write(fs, len, p, buf);
    }

    // Fills the volume holding `dir` with pass patterns through temp files, then removes them.
    // Files are opened DeleteOnClose, so even a crash or kill leaves no filled disk behind.
    // limitBytes caps the fill (tests). Returns bytes written in the first pass.
    public static long WipeFreeSpace(string dir, int passes, IProgress<string>? progress = null,
        CancellationToken ct = default, long limitBytes = long.MaxValue)
    {
        foreach (var stale in Directory.EnumerateDirectories(dir, WipeDirPrefix + "*"))
            try { Directory.Delete(stale, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }

        var root = Directory.CreateDirectory(Path.Combine(dir, WipeDirPrefix + Path.GetRandomFileName())).FullName;
        var patterns = Patterns(Math.Max(passes, 1));
        var files = new List<FileStream>();
        var buf = new byte[BufSize];
        long total = 0;
        try
        {
            if (patterns[0] is { } first) Fill(buf, first);
            for (var full = false; !full && total < limitBytes;)
            {
                var fs = new FileStream(Path.Combine(root, files.Count.ToString()), FileMode.CreateNew,
                    FileAccess.Write, FileShare.None, 1, FileOptions.DeleteOnClose);
                files.Add(fs);
                var chunk = buf.Length;
                while (fs.Position < FileCap && total < limitBytes)
                {
                    ct.ThrowIfCancellationRequested();
                    var n = (int)Math.Min(chunk, limitBytes - total);
                    if (patterns[0] == null) RandomNumberGenerator.Fill(buf.AsSpan(0, n));
                    try { fs.Write(buf, 0, n); total += n; }
                    catch (IOException e) when (IsDiskFull(e))
                    {
                        if (chunk == 4096) { full = true; break; }
                        chunk = 4096; // squeeze the last few MB in small blocks
                    }
                }
                fs.Flush(true);
                progress?.Report($"Pass 1/{patterns.Length}: {total >> 20} MB written");
            }
            for (int p = 1; p < patterns.Length; p++)
            {
                foreach (var fs in files)
                {
                    ct.ThrowIfCancellationRequested();
                    Write(fs, fs.Length, patterns[p], buf);
                }
                progress?.Report($"Pass {p + 1}/{patterns.Length} done");
            }
            return total;
        }
        finally
        {
            foreach (var fs in files) fs.Dispose();
            try { Directory.Delete(root, true); } catch (IOException) { }
        }
    }

    static void Write(FileStream fs, long len, byte[]? pattern, byte[] buf)
    {
        if (pattern != null) Fill(buf, pattern);
        fs.Position = 0;
        for (long left = len; left > 0;)
        {
            var n = (int)Math.Min(buf.Length, left);
            if (pattern == null) RandomNumberGenerator.Fill(buf.AsSpan(0, n));
            fs.Write(buf, 0, n);
            left -= n;
        }
        fs.Flush(true);
    }

    static void Fill(byte[] buf, byte[] pattern)
    {
        for (int i = 0; i < buf.Length; i++) buf[i] = pattern[i % pattern.Length];
    }

    // ERROR_DISK_FULL / ERROR_HANDLE_DISK_FULL
    static bool IsDiskFull(IOException e) => e.HResult is unchecked((int)0x80070070) or unchecked((int)0x80070027);
}
