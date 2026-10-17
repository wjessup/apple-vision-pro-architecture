# Revit → Apple Vision Pro, local-first

Press **View in Apple Vision Pro** in Revit; seconds later the model updates on the headset, in
place, at the scale and position you pinned it. No cloud, no app rebuilds.

```
Revit (Windows)                PC (same machine or any on the LAN)        Apple Vision Pro
┌──────────────────┐  HTTP     ┌───────────────────────────────┐  HTTP+WS  ┌──────────────────┐
│ revit-addin/     │ ────────▶ │ server/  (revitsync, :8787)   │ ────────▶ │ visionos/        │
│ CustomExporter → │  upload   │ content-addressed .usda store │  manifest │ RealityKit scene │
│ one .usda/level  │  changed  │ manifest + revision + Bonjour │  + assets │ pin/move/scale   │
└──────────────────┘  levels   └───────────────────────────────┘  + events └──────────────────┘
```

The three parts share one contract: [`PROTOCOL.md`](PROTOCOL.md).

| Directory | Builds on | Doc |
| --- | --- | --- |
| `server/` | any OS, Python 3.11+ | [server/README.md](server/README.md) |
| `visionos/` | Mac + Xcode, paid developer account for >7-day installs / TestFlight | [visionos/README.md](visionos/README.md) |
| `revit-addin/` | Windows + Revit 2022–2026, Visual Studio / `dotnet` | [revit-addin/README.md](revit-addin/README.md) |

## First run, in order

1. **PC:** `cd server && pip install -e . && revitsync` — note the printed `http://<ip>:8787`.
   Allow TCP 8787 (and UDP 5353 for Bonjour) through Windows Firewall when prompted.
2. **Headset (before the add-in exists):** push any USDZ to prove the viewer:
   `python server/tools/push_model.py --server http://127.0.0.1:8787 --project demo --name Demo model.usdz`
3. **Mac:** `cd visionos && xcodegen generate && open RevitSync.xcodeproj`, sign, run on the
   headset. Connect to the PC, select *demo*, *Show model in room*, drag/scale/pin it.
4. **Windows:** `cd revit-addin/RevitSync.Addin && dotnet build -c Release -p:RevitVersion=2025`,
   restart Revit, open a 3D view, press the button. Watch the headset.
5. Change a wall, press the button again: only that level is re-uploaded and swapped.

The headset app has to be open (its window visible or the immersive space active) to receive
pushes; visionOS suspends background apps, so there is no way to launch it from the PC.

## Measuring the loop

The summary dialog in Revit reports export and upload seconds; the headset's *Revision* row shows
download/load progress per level. Together they answer the spec's first experiment — whether the
bottleneck is Revit tessellation, Wi-Fi, or RealityKit load — on a real room.
