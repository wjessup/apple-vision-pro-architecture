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

The app needs **visionOS 27** or later (shared world anchors and peer-to-peer sharing between
headsets). The *Group Activities* capability (`com.apple.developer.group-session`) is declared in
`project.yml`; XcodeGen writes it to `RevitSync/RevitSync.entitlements`.

## Using it

1. **Server** — the PC running `revitsync` appears under *Server* via Bonjour; tap it. If it
   doesn't (client-isolated Wi-Fi), type the `http://<pc-ip>:8787` URL the server printed. The
   first connection triggers the Local Network permission prompt — allow it. The app allows plain
   HTTP (`NSAllowsArbitraryLoads` in `project.yml`) because the server lives on your own local
   network and is reached by IP address, which App Transport Security would otherwise block.
2. **Project** — tap a project to open it in the room (the mixed immersive space). It downloads
   and loads every level, then listens for `scene.updated`. The window stays open; *Hide model*
   in its Placement section closes the model.
3. **Tools panel** — a single row of icons floats a little below eye level: *Bring window here*,
   *Measure*, *Void*, and a trash icon that deletes the selected measurement or void. Placement,
   scan mesh and the other settings live in the window. A thin white bar sits under the panel;
   pinch and drag it to put the panel wherever you like. It then keeps that spot relative to you:
   with *Tools panel follows me* on, it glides back to that same spot when you turn or walk away
   (turn the toggle off in the window to leave it exactly where it is). The spot is forgotten when
   the model is closed. *Bring window here* closes the window and reopens it in front of you; that
   resets the window to its first tab, scrolled to the top. The model starts as a tabletop
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
   - Placement (position, rotation, scale, corner locks) is shared by every model: they are all
     the same house on the same property, so switching models swaps the building in place and
     moving any one moves them all. It is registered as an ARKit world anchor, so after a relaunch
     or a Digital-Crown recenter the model returns to the same spot in the room. The first time,
     visionOS asks for World Sensing permission.
   - Each model's corners come from its ground floor alone (its plan cut 1 m above level 0), so a
     basement or footing reaching past the walls doesn't move them. If a model's corners are more
     than a foot from those of the model placed last, the Placement section warns that it doesn't
     match the house; it still opens at the shared spot. That usually means its Revit file uses a
     different project base point.
5. **Real world** — while the model is shown, the headset continuously scans what's around you
   and hides any part of the model that sits behind a real object: a tree, a fence, a person.
   The headset only scans about 5 m around you (less in bright sun), and foliage is captured as
   coarse solid shapes, so close trees hide a rough lump rather than leaf-by-leaf. Pieces you
   walk away from are kept rather than dropped, so walking the property builds up a scan of all
   of it; it is saved on the headset once for the whole property and shared by every model,
   pinned to the room every few metres as you walk, and comes back the next time as soon as visionOS recognises any
   of those spots (the *Real world* section says *aligning to previous scan…* until then).
   Walking back over an area shows the fresh scan in place of the kept pieces it covers and
   replaces them once you move on; nothing kept is dropped before its replacement is saved.
   *Clear scan* throws the scan away — use it when the place has changed a lot. *Show scan mesh* draws the scan as a cyan
   wireframe so you can see what is doing the hiding; remembered pieces are dimmer.
   The scan also hides the app's own window if it ends up behind a real object. The visionOS
   Simulator has no scan, so there nothing is hidden.
   Elements marked with **Toggle Void** in Revit (a pool shell, a car ramp) are holes in the scan:
   at 1:1 the scanned lawn or slab inside a void's outline, from the void's top down, stops hiding
   the model, so the pool reads as dug into the real ground while the footings around it stay
   hidden. The holes move with the model when you drag or re-pin it (they settle when the gesture
   ends), the saved scan itself is untouched, and *Show scan mesh* draws the wireframe with the
   holes cut out. Void edges are as fine as the scan's triangles, roughly 5–15 cm.
   Voids can also be marked from the headset at 1:1 with the *Void* icon in the tools panel. It
   has two modes, chosen with the two icons that appear next to it: *surface* — look at any piece
   of the model (a pool shell, a ramp slab) and pinch; its outline seen from above becomes a hole
   in the scan, exactly as if it had been marked *Toggle Void* in Revit; *polygon* — pinch three
   or more spots on the model to trace the outline yourself, then press the checkmark (switching
   modes or turning the tool off drops an unfinished polygon). Voids you make here are drawn as a
   blue outline at 1:1, saved per project, and move with the model; look at the outline and pinch
   to select it (it turns white), then press the trash icon to remove it and close the hole. Voids
   that came from Revit are not drawn and can only be removed in Revit.
6. **Other headsets** — Vision Pros running the app near each other share their room scans and
   the house position directly over peer-to-peer Wi-Fi: Wi-Fi must be on, but no router or
   server is needed. The *Other headsets* section of the Projects tab, below *Real world*, shows:
   - *Share with nearby headsets* — turns finding and talking to other headsets on or off.
   - This headset's name, as the others see it over your head.
   - How this headset is lined up with the others: *Started this site* (the others line up with
     you), *Lined up by scan*, *Lined up by height only, position from house*, *Lined up by house
     placement only*, *Lined up by SharePlay anchor*, *Not lined up yet*, or *Out of line by N cm*
     when the scans disagree.
   - One row per other headset: *Connecting…*, *Syncing N pieces*, *Up to date*, *Needs app
     update* (its app is older or newer than this one), *Not nearby, last seen …*, or *Connection
     failed, retrying*.
   - Network problems, such as Local Network permission refused or Wi-Fi off.
   - *Line up exactly with SharePlay* — with the headsets in a nearby SharePlay session (FaceTime),
     drops a shared world anchor that both headsets see at the same real spot; this lines them up
     at once instead of waiting for the scans to match.

   Headsets that meet first line up roughly from the house placement (the same house sits on the
   same real spot), then exactly once their scans overlap enough: walk near walls facing two
   different ways. Placing the house at 1:1 on any headset moves it on all of them. Every
   headset keeps a copy of the others' scans, so real objects one wearer scanned hide the model
   for everyone, and passes them on to headsets it meets later. Each other wearer has a name tag
   over their head: **green** when lined up by scan or SharePlay anchor, **amber** when lined up
   by the house placement or height only, so the tag may be off by some centimetres. *Clear scan*
   on one headset removes its scan from every headset.
7. **Measure** — measuring works only at real size. Choose *1:1 Real size* in the window's
   *Scale* switch (at 1:20, 1:50, 1:100 or any other scale the ruler icon in the tools panel is
   greyed out). Tap the ruler to turn measuring on — the model's hit shapes are built as each
   level loads, so measuring is ready at once; while it is on, pinching doesn't move the
   model. Look at a spot on the model and pinch to drop a yellow dot, then look at a second spot
   and pinch again: a yellow line appears between them, labelled with the distance in feet and
   inches (nearest ¼"). Labels grow with distance so the numbers stay readable from across a
   site. To delete a measurement, look at its yellow line and pinch to select it (it turns white),
   then press the trash icon in the panel — or tap its label, then the trash button next to it.
   Measurements are saved per project and move with the model. They are hidden whenever the
   model is not at 1:1 and come back when you return to it; leaving 1:1 turns the tool off, hides
   measurements and voids, and drops a half-finished measurement or polygon. Measuring works
   while the position is locked.
8. **Updates** — with *Reload automatically* on, a push from Revit replaces only the changed
   levels, in place; your position and the pin are untouched. Turn it off while presenting and
   use *Load now* when ready.
9. **Offline** — every project you have synced is saved on the headset. Without the server (Wi-Fi
   off, away from the office) the *Project* list still shows them, the last-viewed model loads at
   launch, and any saved project opens at its pinned placement. The server is only needed to
   download new projects and updates; rows marked *not downloaded* or showing a newer server
   revision sync once connected.

## Trying two headsets on site

1. On both headsets: Wi-Fi on (no network has to be joined), open the same project, and allow
   Local Network when asked.
2. Scan separately: each wearer walks part of the property with the model shown at 1:1.
3. Meet within a few metres. In *Other headsets* each should list the other within a few seconds:
   *Connecting…*, then *Syncing N pieces*, then *Up to date*.
4. Check the alignment line: one headset says *Started this site*, the other *Lined up by house
   placement only* (or *Not lined up yet* if the house was never placed on it).
5. Place the house on one headset (drag it or *Place in front of me*, at 1:1). The house on the
   other headset moves to the same real spot.
6. On the joining headset, walk up to walls facing two different ways. Its alignment line changes
   to *Lined up by height only…*, then *Lined up by scan*, and the name tag over the other wearer
   turns from amber to green.
7. Start a FaceTime call between the two (SharePlay nearby) and press *Line up exactly with
   SharePlay* on one: it should say *Lined up by SharePlay anchor* (or stay *Lined up by scan*),
   with the name tags sitting right over the other wearer's head.
8. Walk out of range: the row turns *Not nearby, last seen …*. Walk back: it reconnects and
   syncs only what changed.
9. *Clear scan* on one headset: its scan disappears from the other too (real objects it scanned
   stop hiding the model there), and it lines up again from scratch.

## Code map

| File | Role |
| --- | --- |
| `RevitSync/Protocol.swift` | Codable mirror of `PROTOCOL.md` (manifest, events) |
| `RevitSync/SyncClient.swift` | HTTP + WebSocket client |
| `RevitSync/ModelLibrary.swift` | On-device library: saved manifests + the assets they reference |
| `RevitSync/ServerBrowser.swift` | Bonjour discovery of `_revitsync._tcp` |
| `RevitSync/PeerProtocol.swift` | Headset-to-headset messages, sites, origin records, framing and validation (plain Swift; see `PROTOCOL.md`) |
| `RevitSync/PeerStore.swift` | On-device copies of other headsets' scans, the site placement and tombstones (plain Swift) |
| `RevitSync/PeerLink.swift` | Bonjour `_revitsync-peer._tcp` over peer-to-peer Wi-Fi, one framed TCP connection per nearby headset |
| `RevitSync/SiteSharing.swift` | Sites, catch-up and live sync, lining up with other headsets, the *Other headsets* status and name tags |
| `RevitSync/SharedAnchor.swift` | SharePlay session for *Line up exactly with SharePlay* (shared world anchors) |
| `RevitSync/AppModel.swift` | Connection, project selection, revision diffing, auto/deferred reload |
| `RevitSync/SceneController.swift` | RealityKit root entity, per-partition children, placement + world anchor, corner balls, tool state, measurement and void marks, selection, the tools panel's grab bar |
| `RevitSync/Footprint.swift` | Plan-outline corner detection, the two-corner alignment solve, and `Void` volumes (plain Swift) |
| `RevitSync/ScanMesh.swift` | Scene-reconstruction mesh as invisible occluders plus the wireframe, cut around the model's voids; freezes chunks the headset drops into grid cells placed by the nearest scan pin |
| `RevitSync/ScanGrid.swift` | 1 m scan-frame cells: triangle binning, per-cell merge (plain Swift) |
| `RevitSync/ScanStore.swift` | On-device scan store: `Application Support/scans/<project>/anchors.json` + `cells/*.cell` |
| `RevitSync/ImmersiveView.swift` | Mixed immersive space, gestures (model, grab bar, tool taps, mark selection), the tools-panel and measurement-label attachments |
| `RevitSync/ToolsPanel.swift` | Floating icon-row tools panel (Bring window here, Measure, Void, Delete), the window's placement controls, measurement labels |
| `RevitSync/Measurements.swift` | Measurement model, feet-and-inches formatting, per-project storage |
| `RevitSync/Voids.swift` | Void marks drawn on the headset, per-project storage (plain Swift) |
| `RevitSync/ContentView.swift` | The control window |

Models are loaded with `Entity(contentsOf:)` off the main actor; files live under
`Application Support/models/<project>/<sha256>.<ext>` (excluded from backup) next to that
project's `manifest.json`, so a level that did not change is never downloaded twice. The manifest
is written only after all its levels have loaded, and saving it deletes the files of superseded
revisions.
