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
            var settings = new PushButtonData("RevitSync.Settings", "Sync\nSettings", assembly, typeof(SettingsCommand).FullName)
            {
                ToolTip = "Server address and project name used by View in Apple Vision Pro.",
            };

            panel.AddItem(view);
            panel.AddItem(settings);
            return Result.Succeeded;
        }

        public Result OnShutdown(UIControlledApplication application) => Result.Succeeded;
    }
}
