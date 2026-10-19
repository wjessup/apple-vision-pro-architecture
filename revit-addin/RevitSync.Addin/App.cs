using System;
using System.Reflection;
using Autodesk.Revit.UI;

namespace RevitSync
{
    public class App : IExternalApplication
    {
        public Result OnStartup(UIControlledApplication application)
        {
            var panel = application.CreateRibbonPanel("Vision Pro");
            var assembly = Assembly.GetExecutingAssembly().Location;

            var view = new PushButtonData("RevitSync.View", "View in\nApple Vision Pro", assembly, typeof(ExportCommand).FullName)
            {
                ToolTip = "Export the active 3D view and push it to every connected Apple Vision Pro.",
                LongDescription = "Exports the visible geometry per level as USD, uploads only the levels that changed to the local Revit Sync server, and the headset app swaps them in place.",
            };
            var voids = new PushButtonData("RevitSync.Void", "Toggle\nVoid", assembly, typeof(VoidCommand).FullName)
            {
                ToolTip = "Mark the selected elements as empty space for Apple Vision Pro.",
                LongDescription = "Sets the Vision Pro Void property on the selection (adding it to the project when needed). On the headset, scanned real surfaces inside a void — a pool, a car ramp — stop hiding the model, so the hole shows through the ground. Press again to clear.",
            };
            var settings = new PushButtonData("RevitSync.Settings", "Sync\nSettings", assembly, typeof(SettingsCommand).FullName)
            {
                ToolTip = "Server address and project name used by View in Apple Vision Pro.",
            };

            panel.AddItem(view);
            panel.AddItem(voids);
            panel.AddItem(settings);
            return Result.Succeeded;
        }

        public Result OnShutdown(UIControlledApplication application) => Result.Succeeded;
    }
}
