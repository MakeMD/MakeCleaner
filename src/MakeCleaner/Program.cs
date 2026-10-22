namespace MakeCleaner;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        var settings = new Settings(Settings.ResolveDir(AppContext.BaseDirectory));
        bool Has(string flag) => args.Any(a => a.Equals(flag, StringComparison.OrdinalIgnoreCase));
        if (Has("/auto")) return Schedule.Auto(settings, Has("/shutdown")); // no window at all
        ApplicationConfiguration.Initialize();
        Application.Run(new MainForm(settings));
        return 0;
    }
}
