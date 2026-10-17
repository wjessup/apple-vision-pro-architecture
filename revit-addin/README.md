# Revit add-in: "View in Apple Vision Pro"

Adds a **Vision Pro** ribbon panel to Revit with two buttons:

- **View in Apple Vision Pro** — exports the active 3D view (what is visible, at fine detail) to one
  `.usda` per level, uploads only the levels whose bytes changed to the local sync server, and the
  headset app swaps those levels in place within seconds.
- **Sync Settings** — server URL (default `http://127.0.0.1:8787`, i.e. the server runs on the same
  PC as Revit) and an optional project id / name (defaults derive from the document title).

## Build (Windows, Visual Studio 2022 or `dotnet` CLI)

Revit 2025+ runs on .NET 8, Revit 2022–2024 on .NET Framework 4.8. The project picks the right
target from `RevitVersion`:

```powershell
cd revit-addin\RevitSync.Addin
dotnet build -c Release -p:RevitVersion=2025
```

It references `RevitAPI.dll` / `RevitAPIUI.dll` from `C:\Program Files\Autodesk\Revit <version>`
(override with `-p:RevitDir=...`). A successful build also **installs** the add-in by copying the
DLLs to `%AppData%\Autodesk\Revit\Addins\<version>\RevitSync\` and the manifest next to it. Restart
Revit; accept the "load add-in" prompt once.

Add-ins only load at Revit start, so after each rebuild restart Revit (or use the free
[Add-In Manager](https://github.com/chuongmep/RevitAddInManager) to reload without restarting).

## Use

1. Start the server on the PC: `revitsync` (see `../server/README.md`).
2. Open the headset app, connect to the PC (it shows up under *Server* via Bonjour, or type the
   URL the server printed), pick the project, press **Show model in room**.
3. In Revit, open a 3D view and press **View in Apple Vision Pro**. A summary dialog reports
   export time, upload time and which levels changed.

## What the export does

- Uses `CustomExporter` on the active 3D view, so visibility/graphics overrides, section boxes and
  hidden categories are respected. Level of detail is forced to fine (8/8).
- One partition per level (`level-<id>`), plus `site` for unlevelled elements and
  `link-<title>-level-<id>` for linked models. Partition ids are stable across exports, which is
  what makes the headset's partial reloads work.
- Coordinates: Revit feet, Z-up → metres, Y-up (`x, z, -y`), origin at the **project base point**.
  Level 0 therefore lands at `y = 0` and "1:1" in the headset means your floor is that level.
- Materials: one `UsdPreviewSurface` per Revit material with its shading colour, transparency and
  smoothness. No textures yet — add texture extraction in `UsdaExportContext.MaterialInfo.From`
  when geometry and scale are proven.
- Within each element, faces sharing a material are merged into a single USD mesh, so a wall is one
  prim, not one prim per face.

## Known limits

- Perspective 3D views are rejected by some Revit versions' `CustomExporter`; use an orthographic
  3D view if the export fails immediately.
- Each `.usda` is text; a dense floor can be tens of MB. The server dedupes unchanged levels, so
  only edited levels travel over Wi-Fi. If upload time dominates, switch the writer to `.usdc`
  (binary) via a Python OpenUSD worker on the server — the protocol already carries `ext`.
