namespace MakeCleaner;

static class Program
{
    [STAThread]
    static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new MainForm(new Settings(Settings.ResolveDir(AppContext.BaseDirectory))));
    }
}
