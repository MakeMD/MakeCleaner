namespace MakeCleaner;

// Options section. Saved immediately on change.
public class OptionsPanel : UserControl
{
    public const string SecureDeleteKey = "SecureDeletePasses";

    public OptionsPanel(Settings settings)
    {
        var method = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 320, Name = "secureDelete" };
        foreach (var m in SecureDelete.Methods) method.Items.Add(m.Label);
        var current = settings.GetInt(SecureDeleteKey, 0);
        method.SelectedIndex = Math.Max(0, Array.FindIndex(SecureDelete.Methods, m => m.Passes == current));
        method.SelectedIndexChanged += (_, _) =>
        {
            settings.Set(SecureDeleteKey, SecureDelete.Methods[method.SelectedIndex].Passes);
            settings.Save();
        };

        var layout = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, Padding = new Padding(12) };
        layout.Controls.Add(new Label { Text = "Secure Deletion (applies to every clean)", AutoSize = true });
        layout.Controls.Add(method);
        // Keys match AgeOption= in rules\Windows.ini.
        foreach (var (key, text) in new[] { ("TempOlderThan24h", "Only delete files in Windows Temp folders older than 24 hours"),
                                            ("RecycleBinOlderThan24h", "Only delete Recycle Bin items deleted more than 24 hours ago") })
        {
            var box = new CheckBox { Text = text, AutoSize = true, Checked = settings.GetBool(key, false), Name = key, Margin = new Padding(0, 8, 0, 0) };
            box.CheckedChanged += (_, _) => { settings.Set(key, box.Checked); settings.Save(); };
            layout.Controls.Add(box);
        }
        Controls.Add(layout);
    }
}
