namespace MakeCleaner;

public static class Bytes
{
    public static string Fmt(long b) => b switch
    {
        >= 1L << 30 => $"{b / (double)(1L << 30):0.##} GB",
        >= 1L << 20 => $"{b / (double)(1L << 20):0.##} MB",
        >= 1L << 10 => $"{b / 1024.0:0.##} KB",
        _ => $"{b} B",
    };
}
