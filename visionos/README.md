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
2. **Project** — pick the project (auto-selected when there is only one). It downloads and loads
   every level, then listens for `scene.updated`.
3. **Show model in room** — opens the mixed immersive space. The model starts as a tabletop
   (1:50) in front of you; the small blue sphere is a grab handle that stays the same size at any
   scale.
4. **Placement** — two modes, chosen with the *Basic / Precise* switch (remembered across launches):
   - **Basic:** pinch and drag the handle (or any part of the model) to move it; pinch with both
     hands and pull apart / twist to scale and rotate around the vertical axis.
   - **Precise:** for aligning large models exactly. Only the blue handle can be grabbed, so
     pinching the building does nothing, and dragging the handle moves the project base point,
     which is marked by a ring on the floor. Scale (1:1000–1:1) and rotation (−180°–180°) are set
     with sliders in the window, with ±1% and ±1° / ±0.1° step buttons and exact readouts. Both
     pivot around the base point.
   - *Scale* presets: 1:1, 1:20, 1:50, 1:100. Choosing 1:1 keeps the model's current origin, so
     drag it until the project base point sits where you want the floor to be, or press
     *Place in front of me* which drops the origin on the floor 1.5 m ahead.
   - *Lock position* disables all gestures so a presenter can't nudge it.
   - Placement is saved per project (position, rotation, scale) and also registered as an ARKit
     world anchor, so after a relaunch or a Digital-Crown recenter the model returns to the same
     spot in the room. The first time, visionOS asks for World Sensing permission.
5. **Real world** — while the model is shown, the headset continuously scans what's around you
   and hides any part of the model that sits behind a real object: a tree, a fence, a person.
   The scan reaches only about 5 m (less in bright sun), and foliage is captured as coarse solid
   shapes, so distant trees won't hide anything and close ones hide a rough lump rather than
   leaf-by-leaf. *Show scan mesh* draws the scan as a cyan wireframe so you can see what is
   doing the hiding. The scan also hides the app's own window if it ends up behind a real
   object. The visionOS Simulator has no scan, so there nothing is hidden.
6. **Updates** — with *Reload automatically* on, a push from Revit replaces only the changed
   levels, in place; your position and the pin are untouched. Turn it off while presenting and
   use *Load now* when ready.
7. **Offline** — every project you have synced is saved on the headset. Without the server (Wi-Fi
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
| `RevitSync/SceneController.swift` | RealityKit root entity, per-partition children, placement + world anchor |
| `RevitSync/ScanMesh.swift` | Live scene-reconstruction mesh as invisible occluders, plus the debug wireframe |
| `RevitSync/ImmersiveView.swift` | Mixed immersive space and the drag / magnify / rotate gestures |
| `RevitSync/ContentView.swift` | The control window |

Models are loaded with `Entity(contentsOf:)` off the main actor; files live under
`Application Support/models/<project>/<sha256>.<ext>` (excluded from backup) next to that
project's `manifest.json`, so a level that did not change is never downloaded twice. The manifest
is written only after all its levels have loaded, and saving it deletes the files of superseded
revisions.
