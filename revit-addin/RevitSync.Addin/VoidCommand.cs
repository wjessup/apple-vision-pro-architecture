using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Autodesk.Revit.ApplicationServices;
using Autodesk.Revit.Attributes;
using Autodesk.Revit.DB;
using Autodesk.Revit.UI;

namespace RevitSync
{
    [Transaction(TransactionMode.Manual)]
    public class VoidCommand : IExternalCommand
    {
        public const string ParameterName = "Vision Pro Void";
        private static readonly Guid ParameterGuid = new Guid("6f1c3b52-9d47-4e8a-b2a1-7c5e0d93f4a6");

        private static string SharedParametersPath =>
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "RevitSync", "shared-parameters.txt");

        public Result Execute(ExternalCommandData data, ref string message, ElementSet elements)
        {
            var uidoc = data.Application.ActiveUIDocument;
            var doc = uidoc.Document;
            var app = data.Application.Application;
            var selected = uidoc.Selection.GetElementIds().Select(doc.GetElement).Where(e => e != null).ToList();
            if (selected.Count == 0)
            {
                TaskDialog.Show("Revit Sync", "Select the elements that enclose the empty space first — a pool shell, a ramp, an in-place mass — then press Toggle Void.");
                return Result.Cancelled;
            }

            int value, changed = 0;
            try
            {
                using (var transaction = new Transaction(doc, "Toggle Vision Pro Void"))
                {
                    transaction.Start();
                    EnsureBinding(doc, app, selected);
                    doc.Regenerate();

                    var parameters = selected.Select(e => e.LookupParameter(ParameterName))
                        .Where(p => p != null && !p.IsReadOnly).ToList();
                    value = parameters.Any(p => p.AsInteger() == 0) ? 1 : 0;
                    foreach (var parameter in parameters)
                    {
                        parameter.Set(value);
                        changed++;
                    }
                    transaction.Commit();
                }
            }
            catch (Exception ex)
            {
                message = ex.Message;
                return Result.Failed;
            }

            TaskDialog.Show("Revit Sync", $"{changed} {(changed == 1 ? "element" : "elements")} {(value == 1 ? "marked as void" : "cleared")}");
            return Result.Succeeded;
        }

        private static void EnsureBinding(Document doc, Application app, List<Element> selected)
        {
            var definition = Definition(app);
            CategorySet bound = null;
            var iterator = doc.ParameterBindings.ForwardIterator();
            while (iterator.MoveNext())
            {
                if (iterator.Key.Name == ParameterName && iterator.Current is ElementBinding binding)
                {
                    bound = binding.Categories;
                    break;
                }
            }

            var set = app.Create.NewCategorySet();
            var grew = false;
            if (bound != null)
            {
                foreach (Category category in bound) set.Insert(category);
            }
            foreach (var category in selected.Select(e => e.Category).Where(c => c != null && c.AllowsBoundParameters))
            {
                if (set.Insert(category)) grew = true;
            }

#if NET8_0_OR_GREATER
            var group = GroupTypeId.Data;
#else
            var group = BuiltInParameterGroup.PG_DATA;
#endif
            if (bound == null)
                doc.ParameterBindings.Insert(definition, app.Create.NewInstanceBinding(set), group);
            else if (grew)
                doc.ParameterBindings.ReInsert(definition, app.Create.NewInstanceBinding(set), group);
        }

        private static ExternalDefinition Definition(Application app)
        {
            var previous = app.SharedParametersFilename;
            try
            {
                var path = SharedParametersPath;
                if (!File.Exists(path))
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(path));
                    File.WriteAllText(path, "");
                }
                app.SharedParametersFilename = path;
                var file = app.OpenSharedParameterFile();
                var group = file.Groups.get_Item("RevitSync") ?? file.Groups.Create("RevitSync");
                return group.Definitions.get_Item(ParameterName) as ExternalDefinition
                       ?? (ExternalDefinition)group.Definitions.Create(
                           new ExternalDefinitionCreationOptions(ParameterName, SpecTypeId.Boolean.YesNo) { GUID = ParameterGuid, Visible = true });
            }
            finally
            {
                app.SharedParametersFilename = previous;
            }
        }
    }
}
