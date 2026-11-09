# RevitSync protocol

One contract shared by the Revit add-in (producer), the local server (broker) and the
visionOS app (consumer). Everything is plain HTTP + JSON on the local network.

## Terms

- **Project** — one Revit model, identified by a slug (`sandborn`). Created on first upload.
- **Partition** — one independently replaceable chunk of the model. The add-in partitions
  by Revit level (`level-30245`); the server does not care how partitions are chosen.
- **Asset** — the geometry file of one partition. Stored content-addressed:
  `assets/<sha256>.usda` (or `.usdz`). Immutable; a changed partition is a new asset.
- **Revision** — an integer that increments on every successful upload to a project.

## Coordinate conventions inside assets

- USD `upAxis = "Y"`, `metersPerUnit = 1`.
- Revit is Z-up in feet. The add-in converts `(x, y, z)_revit` → `(x * f, z * f, -y * f)`
  with `f = 0.3048`, so Revit north (+Y) becomes USD −Z.
- Origin is the Revit **project base point**; level 0 sits at USD `y = 0`. "Pin at 1:1"
  therefore means "put this origin on my floor".
- Colors are linear RGB (the add-in converts Revit's sRGB bytes).
- **Voids.** A mesh prim whose name starts with `void_` (the add-in writes `void_e<elementId>_<n>`)
  with `visibility = "invisible"` and no material binding is not geometry to draw but empty
  space the design digs out of the real ground (a pool, a car ramp). The consumer treats
  everything inside the prim's plan outline, from its top downward, as a hole in its room scan,
  so the model shows through there instead of being hidden by the scanned surface. The producer
  writes one per element the user marked as *Vision Pro Void*.
- **Stairs.** An `Xform` prim with no geometry named `stair_e<elementId>_bottom` or
  `stair_e<elementId>_top` marks where one staircase is walked onto: just in front of its first
  step and just past its last step. Its translation's `y` is the walking-surface height of that end
  (model metres), so a consumer can put that floor on the real floor. The producer writes the pair
  for every stair with runs; a consumer ignores an unpaired marker.

## HTTP (base path `/api`)

| Method | Path | Body / result |
| --- | --- | --- |
| `GET` | `/api/projects` | `{"projects":[{"id","name","revision","updatedAt"}]}` |
| `GET` | `/api/projects/{id}/manifest` | current manifest (below); `404` if no revision yet |
| `GET` | `/api/projects/{id}/assets/{sha256}.{ext}` | asset bytes, `Cache-Control: immutable` |
| `HEAD` | `/api/projects/{id}/assets/{sha256}.{ext}` | `200` if the server already has that blob |
| `POST` | `/api/projects/{id}/revisions` | multipart upload (below) → `{"revision","changed","removed","unchanged"}` |
| `WS` | `/api/ws` | server → client events (below) |

### Manifest

```json
{
  "project": "sandborn",
  "name": "Sandborn Hotel",
  "revision": 42,
  "createdAt": "2026-10-17T14:00:00Z",
  "upAxis": "Y",
  "metersPerUnit": 1,
  "partitions": [
    { "id": "level-30245", "name": "Level 1", "file": "assets/3f9a…c1.usda", "sha256": "3f9a…c1", "bytes": 1834022 }
  ]
}
```

`file` is relative to `/api/projects/{id}/`.

### Upload (`POST /api/projects/{id}/revisions`)

`multipart/form-data` with:

- field `manifest` — JSON `{"name": "...", "partitions": [{"id","name","sha256","ext"}]}`
  listing **every** partition of the new revision, including unchanged ones.
- one file part per partition whose blob the server might not have yet; the part name is
  the partition `id`. A producer may skip the file part when `HEAD …/assets/{sha}.{ext}`
  returned `200` (that is how a small change uploads only one level).

The server verifies each uploaded part's sha256 against the manifest, rejects the upload
(`400`) if a listed partition has neither a file part nor an existing blob, stores new blobs,
increments the revision, writes the manifest, and broadcasts `scene.updated`.

Response: `{"revision": 43, "changed": ["level-30245"], "removed": [], "unchanged": ["level-30301"]}`.

`changed` = partitions whose sha differs from the previous revision (or are new);
`removed` = partition ids present before and absent now.

## WebSocket (`/api/ws`)

Text frames, JSON. The server sends:

- on connect: `{"event": "hello", "revisions": {"sandborn": 42}}`
- on upload: `{"event": "scene.updated", "project": "sandborn", "revision": 43, "changed": ["level-30245"], "removed": []}`

Clients send nothing (a `{"event":"ping"}` is tolerated and ignored).

## Discovery

The server advertises Bonjour service `_revitsync._tcp` on its port with TXT record
`path=/api`. Default port **8787**. Manual entry of `http://<ip>:8787` is always possible.

Headsets also advertise and browse a second service, `_revitsync-peer._tcp`, to find each
other (see *Headset to headset*). The server never takes part in it.

## Headset to headset

Nearby Vision Pros share their room scans and the house placement directly, with no server and
no router. Everything below is between apps; the Revit add-in and the server are not involved.

### Discovery and connection

- Each headset advertises Bonjour `_revitsync-peer._tcp` and browses for it, both with
  peer-to-peer Wi-Fi enabled, so headsets find each other over AWDL with Wi-Fi on even when no
  network is joined (and over any shared network too).
- TXT record `device=<uuid>`: the headset's stable device id.
- Of each pair only the headset with the **lower** device id dials, so a pair never has two
  connections. The other side accepts.
- TCP. Every frame is a 4-byte big-endian length followed by a binary property list holding one
  message. A frame may be at most 16 MB; a length above that closes the connection, because the
  stream can no longer be trusted. A frame that fails to decode or validate is dropped and the
  connection stays open.

### Messages

Matrices are column-major 4×4 as 16 floats. Dates are property-list dates.

| Message | Fields | Meaning |
| --- | --- | --- |
| `hello` | `version` (1), `deviceID`, `name`, `site {siteID, created}`, `scanID` (own scan), `have {scanID: highest revision held}`, `tombstones [scanID]` | First message each way. A different `version` means one headset needs an app update; nothing else is exchanged. |
| `tombstones` | `[scanID]` | Scans cleared by their headset. |
| `origin` | `scanID`, `deviceID`, `name`, `site`, `siteFromScan`, `joinedAt`, `quality` (`root`, `sharedAnchor`, `scan`, `heightOnly`, `house`), `revision` | Where one headset's scan frame sits in its site. Only that headset publishes it; the highest `revision` wins. |
| `placement` | `siteID`, `siteFromModel`, `placedAt`, `placedBy`, `placedByName` | The house as last placed by hand at 1:1, in the site frame. |
| `catchUp` | `count` | The next `count` `cell` messages are the catch-up after `hello`. |
| `cell` | `scanID`, `key {ix, iy, iz}`, `revision`, `scannedAt`, `vertices`, `indices` | One 1 m cell of one scan, in that scan's own frame: float32 xyz triples and uint32 triangle indices. |
| `pose` | `scanID`, `scanFromHead` | The sender's head in its own scan frame, sent 4 times a second, for the name tags. |
| `sharedAnchor` | `anchorID`, `siteID`, `siteFromAnchor` | A SharePlay shared world anchor and where it sits in the sender's site. |

### Session order

After both `hello`s, each side sends, in order:

1. `tombstones`, every one it holds;
2. every `origin` record it holds (its own and relayed ones);
3. the newest site `placement`, when it holds one for the peer's site;
4. `catchUp(count)`, then the cells: for every scan, the cells with a revision above the peer's
   `have` for that scan (all of them when the peer has none), in **ascending revision** order,
   skipping the peer's own scan and scans the peer listed as tombstoned.

Cell revisions are unique and increasing per scan and owned by the scan's headset. Sending a
scan's cells oldest first means a receiver cut off part-way holds a prefix of that scan's history,
so its highest revision for the scan is a complete description of what it holds: next time it
says `have` = that revision and receives exactly the rest.

Afterwards, changes go out live: a headset sends each newly saved cell of its own scan as a
`cell`, and relays every cell, origin and placement it accepted to its other connections. A
relayed copy keeps the origin's `scanID` and `revision`. A receiver keeps a cell only when its
revision is higher than the one it holds for that key, so nothing echoes back and forth. Records
for a tombstoned scan are ignored.

### Validation on receipt

Any nearby headset can connect, so nothing received is trusted:

- every matrix must be exactly 16 finite floats;
- cell geometry must be whole xyz triples of finite floats and whole triangles whose indices are
  all in range;
- a `placement` dated more than 5 minutes in the future (a headset with a wrong clock) is rejected.

A rejected message is dropped; the connection stays open.

### Sites

A **site** is a group of headsets sharing one frame. A headset starts its own site (`created` =
now) and is its **root**: the site frame is the root headset's scan frame (`siteFromScan` =
identity, quality `root`). When two headsets in different sites meet, the **older** site wins
(earlier `created`, ties to the smaller id) and the younger headset joins it; each headset's
`siteFromScan` says where its own scan frame sits in the site.

A joining headset first lines up roughly:

- from a SharePlay shared world anchor, which both headsets track at the same real spot
  (quality `sharedAnchor`), or else
- from the house placement: both headsets placed the house on the same real spot, so
  `siteFromScan = siteFromModel × (scanFromModel)⁻¹` (quality `house`);

then refines by matching its scan against the site's scans: height only when the walls seen do
not fix heading and position (`heightOnly`), fully when walls facing two ways or more are seen
(`scan`). Every improvement is published as a new `origin` revision.

The site placement is newest-wins (`placedAt`, ties to the larger `placedBy`). A headset that
accepts a newer placement moves its house there; placing the house by hand at 1:1 publishes a new
one.

**Clear scan** on a headset sends a tombstone for its scan id: every headset deletes its copies,
will not take them back from anyone, and passes the tombstone on. The headset itself starts a new
scan with a new id in a new site, and joins the others again the next time it meets them.
