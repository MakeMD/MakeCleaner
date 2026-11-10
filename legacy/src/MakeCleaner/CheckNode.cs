using System.ComponentModel;

namespace MakeCleaner;

// One checkbox in a Cleaner tree: a group (tri-state, derived from its items) or an item (a Rule or a BrowserItem).
public sealed class CheckNode(string label, object? tag = null, string? warning = null, bool isChecked = false) : INotifyPropertyChanged
{
    // Asks before an item with a warning gets ticked (set by the window: needs an owner for the dialog).
    public static Func<string, string, bool> Confirm = (_, _) => true;

    public string Label { get; } = label;
    public object? Tag { get; } = tag;
    public string? Warning { get; } = warning;
    public List<CheckNode> Children { get; } = [];
    public bool IsExpanded { get; set; }
    CheckNode? parent;
    bool on = isChecked;

    public static CheckNode Group(string label, IEnumerable<CheckNode> items, bool expanded)
    {
        var g = new CheckNode(label) { IsExpanded = expanded };
        foreach (var i in items) { i.parent = g; g.Children.Add(i); }
        return g;
    }

    public bool? IsChecked
    {
        get => Children.Count == 0 ? on
            : Children.All(c => c.on) ? true : Children.Any(c => c.on) ? null : false;
        set
        {
            if (Children.Count == 0)
            {
                if (value == true && Warning != null && !on && !Confirm(Label, Warning)) return; // the box flips back
                Set(value == true);
                parent?.Changed();
                return;
            }
            // Ticking a group ticks its safe items only: risky ones need their own tick (and their own warning).
            // When that changes nothing (all safe ones already on), the click means "untick all" - else a group
            // with an unticked risky item would be stuck in the third state.
            var tick = value == true && Children.Any(c => c.Warning == null && !c.on);
            foreach (var c in Children)
                if (!tick || c.Warning == null) c.Set(tick);
            Changed();
        }
    }

    void Set(bool v) { if (on != v) { on = v; Changed(); } }

    public event PropertyChangedEventHandler? PropertyChanged;
    void Changed() => PropertyChanged?.Invoke(this, new(nameof(IsChecked)));

    public static IEnumerable<CheckNode> Items(IEnumerable<CheckNode> groups) => groups.SelectMany(g => g.Children);
}
