namespace MakeCleaner;

public record ResultRow(string Name, int Items, long Bytes);

// One Analyze -> Clean pass over the ticked items, shared by the GUI and /auto so both clean exactly the same way.
public class CleanPass(Settings settings)
{
    public List<Rule> Scanned { get; private set; } = [];
    public List<FileInfo> Files { get; private set; } = [];
    public List<RegKey> RegKeys { get; private set; } = [];
    public List<Pending> Actions { get; private set; } = [];
    public List<(BrowserItem Item, int Count)> BrowserRows { get; private set; } = [];

    public bool Wipe => Scanned.Any(IsWipe);
    public bool Any => Files.Count + RegKeys.Count + Actions.Count + BrowserRows.Count > 0 || Wipe;

    public static bool IsWipe(Rule r) => r.SpecialKeys.Contains(Special.WipeFreeSpace, StringComparer.OrdinalIgnoreCase);

    // What the Windows / Applications tabs list (before the user's ticks).
    public static List<Rule> WindowsRules() =>
        [.. Rule.ParseIni(Engine.BuiltInRules).Where(r => r.IsDetected()), new Rule { Name = Custom.RuleName, Section = "Advanced" }];

    // Browsers tab owns these browsers; their Winapp2 sections would be duplicates.
    public static List<Rule> AppRules() =>
        [.. Rule.LoadApplications(AppContext.BaseDirectory).Where(r => !Browsers.ReplacedWinapp2Sections.Contains(r.Section ?? ""))];

    // The ticks saved by the GUI; /auto never wipes free space.
    public static (List<Rule> Rules, List<BrowserItem> Browser) Saved(Settings s) =>
        ([.. WindowsRules().Concat(AppRules()).Where(r => !IsWipe(r) && s.GetBool(r.Name, r.Default))],
         [.. Browsers.Detect().Where(i => s.GetBool(i.Key, i.Default))]);

    // One row per ticked item that found something (the results Summary view); Items = files + registry entries + actions, or browser rows.
    public List<ResultRow> Summary { get; private set; } = [];

    // progress = (items done, items total); a cancelled run throws and leaves nothing to clean.
    public void Analyze(IEnumerable<Rule> rules, IEnumerable<BrowserItem> browserItems,
        IProgress<(int Done, int Total)>? progress = null, CancellationToken ct = default)
    {
        Scanned = []; Files = []; RegKeys = []; Actions = []; BrowserRows = []; Summary = [];
        // the Custom entry is rebuilt from Options > Include each time, so list edits apply without a restart
        List<Rule> scanned = [.. rules.Select(r => r.Name == Custom.RuleName ? Custom.IncludeRule(settings) : r),
                              .. browserItems.Select(i => i.Files).Where(r => r.FileKeys.Count > 0)];
        foreach (var r in scanned) r.OlderThanHours = r.AgeOption != null && settings.GetBool(r.AgeOption, false) ? 24 : null;
        var ex = Custom.Excludes(settings);
        var actionItems = browserItems.Where(i => i.Action != null).ToList();
        int done = 0, total = scanned.Count + actionItems.Count;
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        List<FileInfo> files = []; List<RegKey> regKeys = []; List<Pending> actions = []; List<ResultRow> summary = [];
        foreach (var r in scanned)
        {
            ct.ThrowIfCancellationRequested();
            progress?.Report((done++, total));
            var f = Engine.Analyze(r, ex, ct).Where(x => seen.Add(x.FullName)).ToList(); // a file two rules share counts once
            var k = Engine.AnalyzeRegistry(r, ex).Where(x => !regKeys.Contains(x)).ToList();
            var a = Engine.AnalyzeActions(r);
            files.AddRange(f); regKeys.AddRange(k); actions.AddRange(a);
            if (f.Count + k.Count + a.Count > 0) summary.Add(new(r.Name, f.Count + k.Count + a.Count, f.Sum(x => x.Length) + a.Sum(x => x.Bytes)));
        }
        List<(BrowserItem, int)> rows = [];
        foreach (var i in actionItems)
        {
            ct.ThrowIfCancellationRequested();
            progress?.Report((done++, total));
            if (i.Preview() is var n and > 0) { rows.Add((i, n)); summary.Add(new(i.Key, n, 0)); }
        }
        progress?.Report((total, total));
        (Scanned, Files, RegKeys, Actions, BrowserRows, Summary) = (scanned, files, regKeys, actions, rows, summary);
    }

    public string AnalyzeSummary() =>
        $"Analysis complete: {Files.Count} files, {Bytes.Fmt(Files.Sum(f => f.Length))} to be removed, {RegKeys.Count} registry entries"
        + (Actions.Count > 0 ? $", {Actions.Count} other items" : "")
        + (BrowserRows.Count > 0 ? $", {BrowserRows.Sum(a => a.Count)} browser entries" : "")
        + (Wipe ? " + free space wipe" : "");

    // Browsers that are running right now among the analyzed items.
    public List<Browser> RunningBrowsers() =>
        [.. Browsers.Known.Where(b => Scanned.Any(r => r.Name.StartsWith(b.Name + ": ", StringComparison.Ordinal))
                                      || BrowserRows.Any(a => a.Item.Browser == b.Name))
                          .Where(b => b.Running().Count > 0)];

    // skip = browser names whose items stay untouched (still running). Returns the status line.
    public string Clean(ISet<string> skip, IProgress<string>? wipeProgress = null)
    {
        bool Skipped(string ruleName) => skip.Any(b => ruleName.StartsWith(b + ": ", StringComparison.Ordinal));
        var passes = settings.GetInt(SecureDelete.SettingKey, 0);
        // a skipped browser keeps its files; everything else goes as analyzed
        var keep = Scanned.Where(r => Skipped(r.Name)).SelectMany(Engine.Analyze).Select(f => f.FullName).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var r = Engine.Clean(Files.Where(f => !keep.Contains(f.FullName)), passes);
        var rr = Engine.CleanRegistry(RegKeys);
        var ra = Engine.RunActions(Actions);
        var rb = BrowserRows.Select(a => a.Item).Where(i => !skip.Contains(i.Browser)).Sum(i => i.Run());
        foreach (var rule in Scanned.Where(x => !Skipped(x.Name))) Engine.RemoveEmptyDirs(rule);
        var wiped = "";
        if (Wipe)
            try
            {
                // %TEMP% lives on the system drive and is writable without admin; other drives: Tools > Drive Wiper
                SecureDelete.WipeFreeSpace(Path.GetTempPath(), Math.Max(1, passes), wipeProgress);
                wiped = ", free space wiped";
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { wiped = ", free space wipe failed: " + e.Message; }
        Files = []; RegKeys = []; Actions = []; BrowserRows = []; Summary = [];
        return $"Cleaning complete: {r.Deleted} files removed, {Bytes.Fmt(r.BytesFreed)} freed, {r.Skipped} skipped (in use), {rr.Deleted} registry entries removed, {rr.Skipped} skipped"
            + (ra.Deleted + ra.Skipped > 0 ? $", {ra.Deleted} other items done" + (ra.Skipped > 0 ? $" ({ra.Skipped} failed)" : "") : "")
            + (rb > 0 ? $", {rb} browser entries removed" : "")
            + (skip.Count > 0 ? $", skipped running: {string.Join(", ", skip)}" : "") + wiped;
    }
}
