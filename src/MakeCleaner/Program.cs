namespace MakeCleaner;

static class Program
{
    [STAThread]
    static void Main()
    {
        ApplicationConfiguration.Initialize();
        var settings = new Settings(Settings.ResolveDir(AppContext.BaseDirectory));
        Cookies.Keep = () => settings.GetList(Cookies.KeepPrefix);
        Application.Run(new MainForm(settings));
    }
}
