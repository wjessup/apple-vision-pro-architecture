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
