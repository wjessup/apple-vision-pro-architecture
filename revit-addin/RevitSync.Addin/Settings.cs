using System;
using System.Drawing;
using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using Autodesk.Revit.Attributes;
using Autodesk.Revit.DB;
using Autodesk.Revit.UI;

namespace RevitSync
{
    public class Settings
    {
        public string ServerUrl { get; set; } = "http://127.0.0.1:8787";
        public string ProjectId { get; set; } = "";
        public string ProjectName { get; set; } = "";

        private static string Path =>
            System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "RevitSync", "settings.json");

        public static Settings Load()
        {
            if (!File.Exists(Path)) return new Settings();
            return JsonSerializer.Deserialize<Settings>(File.ReadAllText(Path)) ?? new Settings();
        }

        public void Save()
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path));
            File.WriteAllText(Path, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }

        public string ResolveProjectId(Document doc) =>
            Slugify(string.IsNullOrWhiteSpace(ProjectId) ? ModelTitle(doc) : ProjectId);

        public string ResolveProjectName(Document doc) =>
            string.IsNullOrWhiteSpace(ProjectName) ? ModelTitle(doc) : ProjectName;

        public static string ModelTitle(Document doc)
        {
            if (doc.IsWorkshared && !doc.IsDetached)
            {
                var central = ModelPathUtils.ConvertModelPathToUserVisiblePath(doc.GetWorksharingCentralModelPath());
                if (!string.IsNullOrEmpty(central))
                    return System.IO.Path.GetFileNameWithoutExtension(central);
            }
            return doc.Title;
        }

        public static string Slugify(string text)
        {
            var slug = Regex.Replace(text.ToLowerInvariant(), "[^a-z0-9]+", "-").Trim('-');
            if (slug.Length > 64) slug = slug.Substring(0, 64).Trim('-');
            return slug.Length == 0 ? "revit" : slug;
        }
    }

    [Transaction(TransactionMode.ReadOnly)]
    public class SettingsCommand : IExternalCommand
    {
        public Result Execute(ExternalCommandData data, ref string message, ElementSet elements)
        {
            var settings = Settings.Load();
            var doc = data.Application.ActiveUIDocument?.Document;
            using (var form = new SettingsForm(settings, doc))
            {
                if (form.ShowDialog() == DialogResult.OK)
                {
                    settings.Save();
                }
            }
            return Result.Succeeded;
        }
    }

    internal class SettingsForm : Form
    {
        public SettingsForm(Settings settings, Document doc)
        {
            Text = "Revit Sync settings";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterParent;
            ClientSize = new Size(460, 230);
            Font = new Font("Segoe UI", 9f);

            var server = AddRow("Server URL", settings.ServerUrl, 15);
            var id = AddRow("Project id", settings.ProjectId, 60, doc == null ? "" : "blank = " + Settings.Slugify(Settings.ModelTitle(doc)));
            var name = AddRow("Project name", settings.ProjectName, 120, doc == null ? "" : "blank = " + Settings.ModelTitle(doc));

            var ok = new Button { Text = "Save", DialogResult = DialogResult.OK, Location = new Point(280, 185), Size = new Size(80, 28) };
            var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Location = new Point(368, 185), Size = new Size(80, 28) };
            ok.Click += (_, __) =>
            {
                settings.ServerUrl = server.Text.Trim().TrimEnd('/');
                settings.ProjectId = id.Text.Trim();
                settings.ProjectName = name.Text.Trim();
            };
            Controls.Add(ok);
            Controls.Add(cancel);
            AcceptButton = ok;
            CancelButton = cancel;
        }

        private TextBox AddRow(string label, string value, int y, string hint = "")
        {
            Controls.Add(new Label { Text = label, Location = new Point(12, y + 4), AutoSize = true });
            var box = new TextBox { Text = value, Location = new Point(110, y), Size = new Size(338, 24) };
            Controls.Add(box);
            if (hint.Length > 0)
            {
                Controls.Add(new Label { Text = hint, Location = new Point(110, y + 24), AutoSize = true, ForeColor = SystemColors.GrayText });
            }
            return box;
        }
    }
}
