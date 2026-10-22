namespace MakeCleaner;

// Tools section: one tab per tool. Add a tool = add one line.
public class ToolsPanel : UserControl
{
    public ToolsPanel()
    {
        var tabs = new TabControl { Dock = DockStyle.Fill, Name = "toolTabs" };
        tabs.TabPages.Add(Page("Drive Wiper", new DriveWiperPanel()));       // 10
        tabs.TabPages.Add(Page("System Restore", new RestorePanel()));       // 10
        Controls.Add(tabs);
    }

    public static TabPage Page(string text, Control c)
    {
        c.Dock = DockStyle.Fill;
        return new TabPage(text) { Controls = { c } };
    }
}
