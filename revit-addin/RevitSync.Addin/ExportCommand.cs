using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using Autodesk.Revit.Attributes;
using Autodesk.Revit.DB;
using Autodesk.Revit.UI;

namespace RevitSync
{
    [Transaction(TransactionMode.ReadOnly)]
    public class ExportCommand : IExternalCommand
    {
        public Result Execute(ExternalCommandData data, ref string message, ElementSet elements)
        {
            var uidoc = data.Application.ActiveUIDocument;
            var doc = uidoc.Document;
            if (!(doc.ActiveView is View3D view))
            {
                TaskDialog.Show("Revit Sync", "Open a 3D view first. The visible elements of the active 3D view are what gets sent to the headset.");
                return Result.Cancelled;
            }

            var settings = Settings.Load();
            var projectId = settings.ResolveProjectId(doc);
            var projectName = settings.ResolveProjectName(doc);
            var outputDir = Path.Combine(Path.GetTempPath(), "RevitSync", projectId);
            if (Directory.Exists(outputDir)) Directory.Delete(outputDir, true);

            var clock = Stopwatch.StartNew();
            var context = new UsdaExportContext(doc, outputDir);
            var exporter = new CustomExporter(doc, context)
            {
                IncludeGeometricObjects = false,
                ShouldStopOnError = false,
            };

            try
            {
                exporter.Export(view);
            }
            catch (Exception ex)
            {
                message = "Export failed: " + ex.Message;
                return Result.Failed;
            }
            var exportSeconds = clock.Elapsed.TotalSeconds;

            var partitions = context.Partitions;
            if (partitions.Count == 0)
            {
                TaskDialog.Show("Revit Sync", "Nothing to export: the active 3D view has no visible geometry.");
                return Result.Cancelled;
            }

            UploadResult result;
            try
            {
                result = Uploader.Push(settings.ServerUrl, projectId, projectName, partitions);
            }
            catch (ServerRejectedException ex)
            {
                new TaskDialog("Revit Sync") { MainInstruction = "The sync server rejected the upload", MainContent = ex.Message }.Show();
                return Result.Failed;
            }
            catch (Exception ex)
            {
                new TaskDialog("Revit Sync")
                {
                    MainInstruction = "Could not reach the sync server",
                    MainContent = $"{settings.ServerUrl}\n\n{ex.GetBaseException().Message}\n\nIs `revitsync` running on this PC? Check Sync Settings for the address.",
                }.Show();
                return Result.Failed;
            }

            var total = clock.Elapsed.TotalSeconds;
            var summary = new TaskDialog("Revit Sync")
            {
                MainInstruction = $"Revision {result.Revision} sent to Apple Vision Pro",
                MainContent =
                    $"{partitions.Count} levels exported in {exportSeconds:0.0}s, uploaded in {total - exportSeconds:0.0}s.\n" +
                    $"Changed: {Describe(result.Changed)}\nUnchanged: {result.Unchanged.Length}\nRemoved: {Describe(result.Removed)}\n\n" +
                    $"Project: {projectName} ({projectId})",
                CommonButtons = TaskDialogCommonButtons.Close,
            };
            summary.Show();
            return Result.Succeeded;
        }

        private static string Describe(string[] ids) =>
            ids.Length == 0 ? "none" : $"{ids.Length} ({string.Join(", ", ids.Take(6))}{(ids.Length > 6 ? ", …" : "")})";
    }
}
