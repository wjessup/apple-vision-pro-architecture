# Revit Sync — visionOS app

Native visionOS app that connects to the local sync server, shows a Revit model in your room at
true scale (or on a table at 1:50), lets you pin, move, rotate and scale it, and swaps in updated
levels the moment Revit pushes a new revision.

## Open in Xcode (Mac)

The project file is generated from `project.yml` so it stays diff-friendly:

```sh
brew install xcodegen
cd visionos
xcodegen generate
open RevitSync.xcodeproj
```

Then in Xcode: select the **RevitSync** target → Signing & Capabilities → pick your team (bundle id
`com.yourcompany.RevitSync`, change the prefix in `project.yml` if you like). Pair the headset
(Settings → General → Remote Devices on the Vision Pro; Xcode → Window → Devices and Simulators),
select it as the run destination and press Run. It also runs in the visionOS Simulator — networking
to a server on the same Mac works there, but world anchors and hand gestures are limited.

## Using it

1. **Server** — the PC running `revitsync` appears under *Server* via Bonjour; tap it. If it
   doesn't (client-isolated Wi-Fi), type the `http://<pc-ip>:8787` URL the server printed. The
   first connection triggers the Local Network permission prompt — allow it. The app allows plain
   HTTP (`NSAllowsArbitraryLoads` in `project.yml`) because the server lives on your own local
   network and is reached by IP address, which App Transport Security would otherwise block.
2. **Project** — tap a project to open it in the room (the mixed immersive space). It downloads
   and loads every level, then listens for `scene.updated`. The window stays open; *Hide model*
   in its Placement section closes the model.
3. **Tools panel** — a small panel floats a little below eye level with just two tools:
   *Bring window here* and *Measure* (with a one-line hint underneath). Placement, scan mesh and
   the other settings live in the window. *Bring window here* closes the window and reopens it
   next to you; that resets the window to its first tab, scrolled to the top. When you turn away
   or walk off, the panel glides back in front of you; turn off *Tools panel follows me* in the
   window to leave it where it is. The model starts as a tabletop
   (1:50) in front of you; the small blue sphere is a grab handle that stays the same size at any
   scale.
4. **Placement** — three modes, chosen with the *Basic / Precise / Corners* switch (remembered
   across launches). The size is locked to the *Scale* preset you pick, and gestures only move and
   rotate the model. *Advanced → Allow free scaling* (off at every launch) re-enables pinch-to-scale,
   the scale slider and scaling by corners.
   - **Basic:** pinch and drag the handle (or any part of the model) to move it; pinch with both
     hands and twist to rotate around the vertical axis (pull apart to scale, with free scaling on).
   - **Precise:** for aligning large models exactly. Only the blue handle can be grabbed, so
     pinching the building does nothing, and dragging the handle moves the project base point,
     which is marked by a ring on the floor. Rotation (−180°–180°) is set with a slider in the
     window, with ±1° / ±0.1° step buttons and exact readouts; with free scaling on, a scale slider
     (1:1000–1:1) with ±1% steps appears too. Both pivot around the base point.
   - **Corners:** for lining the model up with a real site. Four orange balls, labelled NW, NE, SE
     and SW, sit on the corners of the model's outline seen from above (the largest four-cornered
     shape that fits its outline, so curved or angled lots still get their real corners). Drag a ball
     onto its real-world spot to move the model, then tap it (or press *Lock* in the window) to lock
     it; it turns green. Dragging a second ball now swings the model around the locked corner (and
     sizes it, with free scaling on); tap to lock that too. With two corners locked the model can't
     move, the other balls turn grey, and the locks are saved with the placement. Switching to
     another mode releases the locks and leaves the model where it is.
   - *Scale* presets: 1:1 Real size, 1:20, 1:50, 1:100. Choosing 1:1 keeps the model's current
     origin, so drag it until the project base point sits where you want the floor to be, or press
     *Place in front of me* which drops the origin on the floor 1.5 m ahead. Presets and *Place in
     front of me* are disabled while a corner is locked.
   - *Lock position* disables the move / scale / rotate and corner gestures so a presenter can't
     nudge it; measuring still works.
   - Placement is saved per project (position, rotation, scale) and also registered as an ARKit
     world anchor, so after a relaunch or a Digital-Crown recenter the model returns to the same
     spot in the room. The first time, visionOS asks for World Sensing permission.
5. **Real world** — while the model is shown, the headset continuously scans what's around you
   and hides any part of the model that sits behind a real object: a tree, a fence, a person.
   The headset only scans about 5 m around you (less in bright sun), and foliage is captured as
   coarse solid shapes, so close trees hide a rough lump rather than leaf-by-leaf. Patches you
   walk away from are kept rather than dropped, so walking the property builds up a scan of all
   of it; it is saved on the headset per project and comes back the next time you open that
   project in the same place (the *Real world* section says *aligning to previous scan…* until
   visionOS has recognised the spot). Walking back over an area replaces the kept patch with the
   fresh scan. *Clear scan* throws the project's scan away — use it when you scan a different
   site under the same project or the place has changed a lot. *Show scan mesh* draws the scan
   as a cyan wireframe so you can see what is doing the hiding; remembered patches are dimmer.
   The scan also hides the app's own window if it ends up behind a real object. The visionOS
   Simulator has no scan, so there nothing is hidden.
6. **Measure** — measuring works only at real size. Choose *1:1 Real size* in the window's
   *Scale* switch (at 1:20, 1:50 and 1:100 the *Measure* toggle is greyed out and the panel says
   *Switch to 1:1 Real size to measure*). Turn on *Measure* in the tools panel; while it is on,
   the model can't be moved. Look at a spot on the model and pinch to drop a yellow dot, then look
   at a second spot and pinch again: a yellow line appears between them, labelled with the
   distance in feet and inches (nearest ¼"). Tap a label, then the trash button next to it, to
   delete that measurement. Measurements are saved per project and move with the model. They
   are hidden whenever the model is not at 1:1 and come back when you return to it; leaving 1:1
   while measuring turns *Measure* off and drops a half-finished measurement. Measuring works
   while the position is locked.
7. **Updates** — with *Reload automatically* on, a push from Revit replaces only the changed
   levels, in place; your position and the pin are untouched. Turn it off while presenting and
   use *Load now* when ready.
8. **Offline** — every project you have synced is saved on the headset. Without the server (Wi-Fi
   off, away from the office) the *Project* list still shows them, the last-viewed model loads at
   launch, and any saved project opens at its pinned placement. The server is only needed to
   download new projects and updates; rows marked *not downloaded* or showing a newer server
   revision sync once connected.

## Code map

| File | Role |
| --- | --- |
| `RevitSync/Protocol.swift` | Codable mirror of `PROTOCOL.md` (manifest, events) |
| `RevitSync/SyncClient.swift` | HTTP + WebSocket client |
| `RevitSync/ModelLibrary.swift` | On-device library: saved manifests + the assets they reference |
| `RevitSync/ServerBrowser.swift` | Bonjour discovery of `_revitsync._tcp` |
| `RevitSync/AppModel.swift` | Connection, project selection, revision diffing, auto/deferred reload |
| `RevitSync/SceneController.swift` | RealityKit root entity, per-partition children, placement + world anchor, corner balls |
| `RevitSync/Footprint.swift` | Plan-outline corner detection and the two-corner alignment solve (plain Swift) |
| `RevitSync/ScanMesh.swift` | Scene-reconstruction mesh as invisible occluders plus the wireframe; keeps and reloads patches the headset drops |
| `RevitSync/ScanStore.swift` | On-device scan store: `Application Support/scans/<project>/` patches + anchor id |
| `RevitSync/ImmersiveView.swift` | Mixed immersive space, gestures, the tools-panel and measurement-label attachments |
| `RevitSync/ToolsPanel.swift` | Following tools panel (Bring window here, Measure), the window's placement controls, measurement labels |
| `RevitSync/Measurements.swift` | Measurement model, feet-and-inches formatting, per-project storage |
| `RevitSync/ContentView.swift` | The control window |

Models are loaded with `Entity(contentsOf:)` off the main actor; files live under
`Application Support/models/<project>/<sha256>.<ext>` (excluded from backup) next to that
project's `manifest.json`, so a level that did not change is never downloaded twice. The manifest
is written only after all its levels have loaded, and saving it deletes the files of superseded
revisions.
