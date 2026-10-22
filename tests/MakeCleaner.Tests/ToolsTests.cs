using MakeCleaner;
using Microsoft.Win32;

// Everything runs under HKCU\Software\MakeCleanerTest-t08-<guid> and a temp folder; nothing real is touched.
public class ToolsTests : IDisposable
{
    readonly string sub = $@"Software\MakeCleanerTest-t08-{Guid.NewGuid():N}"; // own top-level branch: see RegistryTests.branch
    readonly string dir = Directory.CreateTempSubdirectory("mc-t08-").FullName;
    string Root => $@"HKCU\{sub}";

    public void Dispose()
    {
        Registry.CurrentUser.DeleteSubKeyTree(sub, false);
        Directory.Delete(dir, true);
    }

    RegistryKey Key(string rel) => Registry.CurrentUser.CreateSubKey($@"{sub}\{rel}");

    void Values(string rel, params (string Name, object Value)[] values)
    {
        using var k = Key(rel);
        foreach (var (n, v) in values) k.SetValue(n, v);
    }

    [Fact]
    public void Uninstall_list_filters_like_programs_and_features()
    {
        Values(@"U1\App", ("DisplayName", "App"), ("DisplayVersion", "1.0"), ("UninstallString", @"""C:\App\un.exe"" /x"),
            ("Publisher", "Acme"), ("InstallDate", "20260101"), ("EstimatedSize", 2048));
        Values(@"U1\Sys", ("DisplayName", "Sys"), ("UninstallString", "x"), ("SystemComponent", 1));
        Values(@"U1\Patch", ("DisplayName", "Patch"), ("UninstallString", "x"), ("ParentKeyName", "App"));
        Values(@"U1\Upd", ("DisplayName", "Upd"), ("UninstallString", "x"), ("ReleaseType", "Update"));
        Values(@"U1\NoCmd", ("DisplayName", "NoCmd"));
        Values(@"U1\{11111111-2222-3333-4444-555555555555}", ("DisplayName", "Msi App"), ("WindowsInstaller", 1), ("NoModify", 1));
        Values(@"U2\Other", ("DisplayName", "Other"), ("UninstallString", "x"));

        var apps = Uninstall.Read($@"{Root}\U1", $@"{Root}\U2");

        Assert.Equal(["App", "Msi App", "Other"], apps.Select(a => a.Name));
        var app = apps[0];
        Assert.Equal(("Acme", 2048L, @"""C:\App\un.exe"" /x"), (app.Publisher, app.SizeKb, app.UninstallCommand));
        Assert.Null(app.RepairCommand); // no ModifyPath
        var msi = apps[1];
        Assert.Equal("msiexec.exe /x {11111111-2222-3333-4444-555555555555}", msi.UninstallCommand);
        Assert.Equal("msiexec.exe /fomus {11111111-2222-3333-4444-555555555555}", msi.RepairCommand);
        Assert.Null(msi.ChangeCommand); // NoModify

        Assert.True(Uninstall.DeleteEntry(app));
        Assert.Null(Reg.Open(app.Key));
    }

    [Theory]
    [InlineData(@"""C:\Program Files\A\un.exe"" /S", @"C:\Program Files\A\un.exe", "/S")]
    [InlineData(@"C:\Program Files\A\un.exe /S", @"C:\Program Files\A\un.exe", "/S")]
    [InlineData(@"MsiExec.exe /X{ABC}", "MsiExec.exe", "/X{ABC}")]
    [InlineData(@"C:\a\un.exe", @"C:\a\un.exe", "")]
    [InlineData(@"rundll32 shell32.dll,Foo", "rundll32", "shell32.dll,Foo")]
    public void SplitCommand_handles_quoted_and_bare_paths(string cmd, string exe, string args) =>
        Assert.Equal((exe, args), Uninstall.SplitCommand(cmd));

    [Fact]
    public void Approved_bytes_match_task_manager_format()
    {
        Assert.True(Startup.IsApproved(null));
        Assert.True(Startup.IsApproved([2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
        Assert.True(Startup.IsApproved([6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
        var off = Startup.ApprovedBytes(false, new DateTime(2026, 10, 22, 0, 0, 0, DateTimeKind.Utc));
        Assert.Equal(12, off.Length);
        Assert.False(Startup.IsApproved(off));
        Assert.Equal(new DateTime(2026, 10, 22).ToFileTimeUtc(), BitConverter.ToInt64(off, 4));
        Assert.Equal([2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], Startup.ApprovedBytes(true, DateTime.UtcNow));
    }

    [Fact]
    public void Run_entry_disable_enable_delete_is_reversible()
    {
        Values("Run", ("Tool", @"C:\tool.exe -min"));
        var item = Assert.Single(Startup.ReadRun($@"{Root}\Run", $@"{Root}\Approved"));
        Assert.True(item.Enabled);

        Assert.True(Startup.SetEnabled(item, false));
        item = Assert.Single(Startup.ReadRun($@"{Root}\Run", $@"{Root}\Approved"));
        Assert.False(item.Enabled);
        Assert.Equal(@"C:\tool.exe -min", item.Command); // the Run value itself is untouched

        Assert.True(Startup.SetEnabled(item, true));
        item = Assert.Single(Startup.ReadRun($@"{Root}\Run", $@"{Root}\Approved"));
        Assert.True(item.Enabled);

        Assert.True(Startup.Delete(item));
        Assert.Empty(Startup.ReadRun($@"{Root}\Run", $@"{Root}\Approved"));
        using var approved = Reg.Open($@"{Root}\Approved");
        Assert.Null(approved!.GetValue("Tool"));
    }

    [Fact]
    public void Startup_folder_item_toggle_and_delete()
    {
        var lnk = Path.Combine(dir, "app.lnk");
        File.WriteAllText(lnk, "x");
        File.WriteAllText(Path.Combine(dir, "desktop.ini"), "x");
        var item = Assert.Single(Startup.ReadFolder(dir, $@"{Root}\Folder"));
        Assert.Equal(("app.lnk", true), (item.Name, item.Enabled));

        Assert.True(Startup.SetEnabled(item, false));
        Assert.False(Assert.Single(Startup.ReadFolder(dir, $@"{Root}\Folder")).Enabled);

        Assert.True(Startup.Delete(item));
        Assert.False(File.Exists(lnk));
    }

    [Fact]
    public void Context_menu_handler_block_unblock_delete()
    {
        const string clsid = "{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}";
        Values(@"Classes\Directory\shellex\ContextMenuHandlers\FooExt", ("", clsid));
        Values($@"Classes\CLSID\{clsid}", ("", "Foo Extension"));
        Values($@"Classes\CLSID\{clsid}\InprocServer32", ("", @"C:\foo.dll"));
        string classes = $@"{Root}\Classes", blocked = $@"{Root}\Blocked";

        var item = Assert.Single(Startup.ReadContextMenu(classes, blocked));
        Assert.Equal(("Foo Extension", @"C:\foo.dll", clsid, true), (item.Name, item.Command, item.Id, item.Enabled));

        Assert.True(Startup.SetEnabled(item, false));
        item = Assert.Single(Startup.ReadContextMenu(classes, blocked));
        Assert.False(item.Enabled);
        Assert.True(Startup.SetEnabled(item, true));
        Assert.True(Assert.Single(Startup.ReadContextMenu(classes, blocked)).Enabled);

        Assert.True(Startup.Delete(item));
        Assert.Empty(Startup.ReadContextMenu(classes, blocked));
    }

    [Fact]
    public void Services_list_skips_drivers_and_user_templates_and_remembers_start()
    {
        Values(@"Svc\AutoSvc", ("Type", 16), ("Start", 2), ("DisplayName", "Auto Service"), ("ImagePath", @"C:\Acme\svc.exe"));
        Values(@"Svc\OffSvc", ("Type", 32), ("Start", 4), ("ImagePath", @"C:\Windows\system32\svchost.exe -k x"), (Startup.PrevStartValue, 2));
        Values(@"Svc\Driver", ("Type", 1), ("Start", 3));
        Values(@"Svc\UserTmpl", ("Type", 0x50), ("Start", 3));
        Values(@"Svc\Boot", ("Type", 16), ("Start", 0));

        var items = Startup.ReadServices($@"{Root}\Svc").OrderBy(i => i.Id).ToList();
        Assert.Equal(["AutoSvc", "OffSvc"], items.Select(i => i.Id));
        var (auto, off) = (items[0], items[1]);
        Assert.Equal(("Auto Service", "Auto", true), (auto.Name, auto.Info, auto.Enabled));
        Assert.Equal(("Disabled", false), (off.Info, off.Enabled));

        Assert.Contains("start= disabled", Startup.ServiceToggleArgs(auto, false));
        Assert.Contains("/d 2", Startup.ServiceToggleArgs(auto, false));
        Assert.Contains("start= auto", Startup.ServiceToggleArgs(off, true)); // restored from the remembered value
        Assert.False(Startup.IsSystemService(auto));
        Assert.True(Startup.IsSystemService(off));
        Assert.False(Startup.Delete(off)); // system services are never deleted
    }

    [Fact]
    public void Scheduled_tasks_enumerate_read_only() => Assert.NotNull(Startup.ReadTasks());
}
