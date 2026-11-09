import ARKit
import Metal
import RealityKit

/// Scene-reconstruction geometry, kept for the whole property. ARKit only maintains mesh anchors
/// near the wearer and reports the rest as removed; a removed chunk is binned into 1 m cells of a
/// property-wide scan frame and saved. The scan frame is pinned to the room by world anchors spaced
/// through the property; each cell is placed by the pin that owns it, so the scan is back as soon
/// as visionOS recognises any one pin, and a live chunk only hides the cells it has triangles in.
/// The saved geometry is always complete; what is displayed is that geometry minus the triangles
/// inside the model's voids (pools, ramps), recut whenever voids, placement or pins move.
/// Tracking drifts over long walks, so remembered cells can sit a few centimetres off the live
/// scan; each pin carries a session-only correction found by registering live chunks against its
/// cells, and only geometry that still disagrees after that is treated as a real change.
@MainActor
@Observable
final class ScanMesh {
    let root = Entity()

    var isVisible = false {
        didSet {
            live.values.forEach { $0.wireframe.isEnabled = isVisible }
            pendingFreeze.forEach { $0.wireframe.isEnabled = isVisible }
            cells.values.forEach { $0.wireframe.isEnabled = isVisible }
        }
    }

    private(set) var patchCount = 0
    private(set) var rememberedCount = 0
    private(set) var isAligned = false

    private struct Patch {
        let occluder: ModelEntity
        let wireframe: ModelEntity
        var mesh: MeshResource
        var geometry = ScanGeometry()
        var originFromPatch = matrix_identity_float4x4
        /// Cells the chunk has triangles in.
        var covering: Set<CellKey> = []
        /// Covered cells it hides: all but those whose pin last registered as drift.
        var hiding: Set<CellKey> = []

        var position: SIMD3<Float> { ScanMesh.translation(originFromPatch) }
    }

    private struct Cell {
        let occluder: ModelEntity
        let wireframe: ModelEntity
        let mesh: MeshResource
        let record: ScanCellRecord
    }

    private struct Anchor {
        let scanFromAnchor: simd_float4x4
        var originFromAnchor: simd_float4x4?
        let group: Entity
        /// Session-only drift correction applied on top of `base`, in the origin frame.
        var correction = matrix_identity_float4x4
        /// Bumped whenever `correction` changes, so a registration started before is dropped.
        var generation = 0
        /// Origin-from-scan this pin was last placed by, before the correction.
        var base: simd_float4x4?
        /// The latest registration of a live chunk against this pin's cells found only drift.
        var drifting = false
        var lastRegistration: Date?
        var registering = false
    }

    struct PinPose {
        let id: UUID
        let originFromPin: simd_float4x4
        let tracked: Bool
        /// Metres the drift correction moves the pin.
        let correction: Float
    }

    private static let registrationInterval: TimeInterval = 2
    private static let relocalisationShift: Float = 0.05
    private static let relocalisationYaw: Float = 0.5 * .pi / 180

    private let liveRoot = Entity()
    private let rememberedRoot = Entity()
    private var live: [UUID: Patch] = [:]
    private var pendingFreeze: [Patch] = []
    private var cells: [CellKey: Cell] = [:]
    private var anchors: [UUID: Anchor] = [:]
    private var coverCounts: [CellKey: Int] = [:]
    private var voids: [Footprint.Void] = []
    private var worldFromModel = matrix_identity_float4x4

    private let liveMaterial: UnlitMaterial = {
        var material = UnlitMaterial(color: .systemCyan)
        material.triangleFillMode = .lines
        // Drawn over everything so the whole scan is visible, including patches hidden behind the model.
        material.readsDepth = false
        return material
    }()

    private let rememberedMaterial: UnlitMaterial = {
        var material = UnlitMaterial(color: .systemCyan)
        material.triangleFillMode = .lines
        material.blending = .transparent(opacity: 0.4)
        material.readsDepth = false
        return material
    }()

    init() {
        root.name = "scanMesh"
        liveRoot.name = "scanLive"
        rememberedRoot.name = "scanRemembered"
        rememberedRoot.isEnabled = false
        root.addChild(liveRoot)
        root.addChild(rememberedRoot)
    }

    // MARK: Live updates

    func apply(_ update: AnchorUpdate<MeshAnchor>) async {
        let anchor = update.anchor
        switch update.event {
        case .added, .updated:
            guard let mesh = try? await MeshResource(from: anchor) else { return }
            var patch = live[anchor.id] ?? makePatch(mesh: mesh)
            patch.mesh = mesh
            patch.originFromPatch = anchor.originFromAnchorTransform
            patch.occluder.transform = Transform(matrix: patch.originFromPatch)
            patch.geometry = ScanGeometry(vertices: Self.packed(anchor.geometry.vertices), indices: Self.packed(anchor.geometry.faces))
            display(patch, material: liveMaterial)
            cover(&patch)
            live[anchor.id] = patch
            registerDrift(patchID: anchor.id)
        case .removed:
            guard let patch = live.removeValue(forKey: anchor.id) else { return }
            freeze(patch)
        }
        recount()
    }

    /// Freezes every live patch; called when the immersive space closes.
    func flushLive() {
        for patch in live.values { freeze(patch) }
        live.removeAll()
        recount()
    }

    /// Writes the live set to cells while ARKit keeps maintaining it, so leaving the foreground
    /// loses nothing; the cells stay hidden under the live patches and are rewritten when they freeze.
    func saveLive() {
        guard isAligned else { return }
        for patch in live.values { writeCells(from: patch) }
        recount()
    }

    // MARK: Model voids

    func setVoids(_ voids: [Footprint.Void], worldFromModel: simd_float4x4) {
        self.voids = voids
        self.worldFromModel = worldFromModel
        for patch in live.values { display(patch, material: liveMaterial) }
        for patch in pendingFreeze { display(patch, material: rememberedMaterial) }
        for cell in cells.values { display(cell) }
    }

    // MARK: Pins

    var anchorIDs: [UUID] { Array(anchors.keys) }

    func hasAnchor(_ id: UUID) -> Bool { anchors[id] != nil }

    /// Session-origin pose of every pin with its drift correction applied: tracked ones where
    /// visionOS reports them, the rest estimated through the nearest tracked pin. Empty while
    /// nothing is tracked.
    var pinPoses: [PinPose] {
        anchors.compactMap { id, anchor in
            guard let originFromScan = originFromScan(for: id), let base = anchor.base else { return nil }
            let pose = originFromScan * anchor.scanFromAnchor
            let correction = simd_distance(Self.translation(pose), Self.translation(base * anchor.scanFromAnchor))
            return PinPose(id: id, originFromPin: pose, tracked: anchor.originFromAnchor != nil, correction: correction)
        }
    }

    func originFromScan(near position: SIMD3<Float>) -> simd_float4x4? {
        nearestTracked(toOrigin: position).flatMap(originFromScan(for:))
    }

    /// The scan frame as placed by the pin nearest a scan-frame position, tracked or not.
    func originFromScan(nearScan position: SIMD3<Float>) -> simd_float4x4? {
        nearestPin(toScan: position).flatMap(originFromScan(for:))
    }

    func addAnchor(id: UUID, scanFromAnchor: simd_float4x4, originFromAnchor: simd_float4x4) {
        anchors[id] = Anchor(scanFromAnchor: scanFromAnchor, originFromAnchor: originFromAnchor, group: makeGroup())
        ScanStore.saveAnchors(anchors.map { ScanAnchorRecord(id: $0.key, scanFromAnchor: Self.columns($0.value.scanFromAnchor)) })
        refreshAlignment()
    }

    func anchorUpdated(_ id: UUID, originFromAnchor: simd_float4x4, tracked: Bool) {
        guard anchors[id] != nil else { return }
        anchors[id]?.originFromAnchor = tracked ? originFromAnchor : nil
        refreshAlignment()
    }

    // MARK: Saved scan

    func load(anchors: [ScanAnchorRecord], cells: [CellKey: ScanCellRecord]) {
        removeAll()
        for record in anchors {
            self.anchors[record.id] = Anchor(scanFromAnchor: Self.matrix(record.scanFromAnchor), group: makeGroup())
        }
        for (key, record) in cells { setCell(key, record) }
        recount()
    }

    func clear() {
        removeAll()
        recount()
    }

    // MARK: Other headsets' scans (driven by SiteSharing)

    /// How live chunks are matched against reference scans of other headsets in this site.
    enum SiteMatchMode: Equatable {
        /// From a rough start (house placed by hand): wide search, `ScanAlignment.isJoinMatch`.
        case join
        /// Already lined up: the drift search, `ScanAlignment.isDrift`.
        case refine

        var radii: [Float] { self == .join ? ScanAlign.joinRadii : ScanAlign.radii }
    }

    /// Gives each of this headset's cell writes its revision. Set by `SiteSharing`; writes get
    /// revision 0 while unset.
    var nextCellRevision: (() -> Int)?
    /// Called after `writeCells` saved own cells, with every record it wrote, in write order.
    var onCellsWritten: (([(key: CellKey, record: ScanCellRecord)]) -> Void)?

    /// This headset's own cells, for sending to other headsets.
    var ownCells: [CellKey: ScanCellRecord] { [:] }

    /// Shows or replaces another headset's scan. `myScanFromPeerScan` maps that headset's scan
    /// frame into this one's; nil keeps the scan loaded but hidden (another site, or not lined up
    /// yet). Live chunks are matched against `reference` scans while `siteMatch` is set.
    func setPeerScan(_ scanID: UUID, myScanFromPeerScan: simd_float4x4?, reference: Bool, cells: [PeerCell]) {}

    /// Moves (or hides, with nil) a peer scan already set, without resending its cells.
    func setPeerPlacement(_ scanID: UUID, myScanFromPeerScan: simd_float4x4?, reference: Bool) {}

    /// Adds or replaces one cell of a peer scan already set.
    func updatePeerCell(_ cell: PeerCell) {}

    func removePeerScan(_ scanID: UUID) {}

    func removeAllPeerScans() {}

    /// Matching of live chunks against reference peer scans; nil turns it off.
    var siteMatch: SiteMatchMode?

    /// One match result. `correction` (in this headset's scan frame) moves the reference scans
    /// from where they are drawn now to where they line up with the live scan, so the caller
    /// applies `siteFromScan = siteFromScan * correction.inverse`. Called for every finished
    /// match, accepted or not; results computed against a placement that changed meanwhile are
    /// dropped, never reported.
    var onSiteMatch: ((_ result: ScanAlignment, _ correction: simd_float4x4, _ mode: SiteMatchMode) -> Void)?

    // MARK: Internals

    private func removeAll() {
        live.values.forEach { $0.occluder.removeFromParent() }
        pendingFreeze.forEach { $0.occluder.removeFromParent() }
        anchors.values.forEach { $0.group.removeFromParent() }
        live.removeAll()
        pendingFreeze.removeAll()
        cells.removeAll()
        anchors.removeAll()
        coverCounts.removeAll()
        rememberedRoot.isEnabled = false
        isAligned = false
    }

    /// Places every pin's group: by its own tracked pose, else by the nearest tracked pin's estimate
    /// of the scan frame, then its drift correction. A correction is dropped when the pose under it
    /// jumps (visionOS relocalised the pin, or it is now placed through another pin), since it was
    /// measured against the old one. Gaining the first tracked pin commits what was frozen without one.
    private func refreshAlignment() {
        let aligned = anchors.values.contains { $0.originFromAnchor != nil }
        var redrift = false
        for id in Array(anchors.keys) {
            let base = base(for: id)
            if let base, let old = anchors[id]!.base, !Self.jumped(from: old, to: base, at: anchors[id]!.scanFromAnchor) {
                anchors[id]!.base = base
            } else {
                anchors[id]!.base = base
                if anchors[id]!.correction != matrix_identity_float4x4 || anchors[id]!.drifting { redrift = true }
                anchors[id]!.correction = matrix_identity_float4x4
                anchors[id]!.generation += 1
                anchors[id]!.drifting = false
            }
            if let originFromScan = originFromScan(for: id) { anchors[id]!.group.transform = Transform(matrix: originFromScan) }
        }
        if redrift, aligned { recoverLive() }
        // Moving a group moves its cells relative to the voids.
        if !voids.isEmpty { cells.values.forEach(display) }
        rememberedRoot.isEnabled = aligned
        let wasAligned = isAligned
        isAligned = aligned
        guard aligned != wasAligned else { return }
        if aligned {
            recoverLive()
            for patch in pendingFreeze { commit(patch) }
            pendingFreeze.removeAll()
        } else {
            for id in live.keys {
                live[id]?.covering = []
                live[id]?.hiding = []
            }
            coverCounts.removeAll()
            cells.values.forEach { $0.occluder.isEnabled = true }
        }
        recount()
    }

    private func recoverLive() {
        for id in live.keys {
            var patch = live[id]!
            cover(&patch)
            live[id] = patch
        }
    }

    /// Origin-from-scan as pin `id` places it before its correction: its own tracked pose, else the
    /// nearest tracked pin's. Nil while nothing is tracked.
    private func base(for id: UUID) -> simd_float4x4? {
        let anchor = anchors[id]!
        guard let via = anchor.originFromAnchor != nil ? id : nearestTracked(toScan: Self.translation(anchor.scanFromAnchor)) else { return nil }
        let pin = anchors[via]!
        return pin.originFromAnchor! * pin.scanFromAnchor.inverse
    }

    /// Where pin `id`'s group puts the scan frame this session: its base with its drift correction.
    private func originFromScan(for id: UUID) -> simd_float4x4? {
        guard let anchor = anchors[id], let base = anchor.base else { return nil }
        return anchor.correction * base
    }

    private static func jumped(from old: simd_float4x4, to new: simd_float4x4, at scanFromPin: simd_float4x4) -> Bool {
        let a = old * scanFromPin, b = new * scanFromPin
        if simd_distance(translation(a), translation(b)) > relocalisationShift { return true }
        let turn = (simd_quatf(b) * simd_quatf(a).inverse).angle
        return min(turn, 2 * .pi - turn) > relocalisationYaw
    }

    private func nearestPin(toScan position: SIMD3<Float>) -> UUID? {
        anchors.min { simd_distance(Self.translation($0.value.scanFromAnchor), position) < simd_distance(Self.translation($1.value.scanFromAnchor), position) }?.key
    }

    private func nearestTracked(toOrigin position: SIMD3<Float>) -> UUID? {
        anchors.lazy
            .compactMap { id, anchor in anchor.originFromAnchor.map { (id, simd_distance(Self.translation($0), position)) } }
            .min { $0.1 < $1.1 }?.0
    }

    private func nearestTracked(toScan position: SIMD3<Float>) -> UUID? {
        anchors.lazy
            .filter { $0.value.originFromAnchor != nil }
            .min { simd_distance(Self.translation($0.value.scanFromAnchor), position) < simd_distance(Self.translation($1.value.scanFromAnchor), position) }?
            .key
    }

    /// Hides the remembered cells a live chunk has triangles in, except those whose pin last
    /// registered as drift: once corrected they line up with the chunk, so hiding them would only
    /// flicker.
    private func cover(_ patch: inout Patch) {
        guard let originFromScan = originFromScan(near: patch.position) else { return }
        patch.covering = ScanGrid.keys(of: patch.geometry, scanFromGeometry: Self.columns(originFromScan.inverse * patch.originFromPatch))
        let hiding = patch.covering.filter { key in
            guard let owner = cells[key]?.record.owner else { return true }
            return anchors[owner]?.drifting != true
        }
        for key in patch.hiding.subtracting(hiding) { release(key) }
        for key in hiding.subtracting(patch.hiding) {
            coverCounts[key, default: 0] += 1
            cells[key]?.occluder.isEnabled = false
        }
        patch.hiding = hiding
    }

    /// Registers the live chunk against the remembered cells it overlaps, once per pin every two
    /// seconds, off the main actor. Drift composes into the pin's correction and keeps its cells
    /// shown; anything else (a real change, or too little overlap to tell) leaves them hidden to be
    /// replaced when the chunk freezes.
    private func registerDrift(patchID: UUID) {
        guard isAligned, let patch = live[patchID] else { return }
        let now = Date()
        let owners = Set(patch.covering.compactMap { cells[$0]?.record.owner })
        for owner in owners {
            guard let anchor = anchors[owner], !anchor.registering,
                  anchor.lastRegistration.map({ now.timeIntervalSince($0) >= Self.registrationInterval }) ?? true,
                  let originFromScan = originFromScan(for: owner) else { continue }
            let remembered = patch.covering.compactMap { cells[$0] }.filter { $0.record.owner == owner }.map(\.record.vertices)
            let liveGeometry = patch.geometry
            let originFromPatch = patch.originFromPatch
            let generation = anchor.generation
            anchors[owner]!.registering = true
            anchors[owner]!.lastRegistration = now
            Task {
                let result = await Task.detached {
                    Self.register(remembered: remembered, originFromScan: originFromScan, live: liveGeometry, originFromPatch: originFromPatch)
                }.value
                self.registered(owner, result, generation: generation)
            }
        }
    }

    private nonisolated static func register(remembered: [Data], originFromScan: simd_float4x4, live: ScanGeometry, originFromPatch: simd_float4x4) -> ScanAlignment {
        let livePositions = ScanGrid.positions(live.vertices).map { transformed(originFromPatch, $0) }
        guard let first = livePositions.first else { return ScanAlignment() }
        // Only remembered geometry inside what the chunk observed (plus the search radius) can match.
        let margin = SIMD3<Float>(repeating: ScanAlign.radii[0])
        let lo = livePositions.reduce(first, simd_min) - margin
        let hi = livePositions.reduce(first, simd_max) + margin
        let source = remembered.flatMap(ScanGrid.positions).map { transformed(originFromScan, $0) }.filter { all($0 .>= lo) && all($0 .<= hi) }
        return ScanAlign.register(source: source, target: ScanAlign.Target(positions: livePositions, indices: ScanGrid.indices(live.indices)))
    }

    private func registered(_ owner: UUID, _ result: ScanAlignment, generation: Int) {
        guard anchors[owner] != nil else { return }
        anchors[owner]!.registering = false
        // The pose under the correction moved while registering; the result is against the old one.
        guard anchors[owner]!.generation == generation else { return }
        let drifting = result.isDrift
        if drifting {
            anchors[owner]!.correction = Self.matrix(result.columns) * anchors[owner]!.correction
            anchors[owner]!.generation += 1
            if let originFromScan = originFromScan(for: owner) { anchors[owner]!.group.transform = Transform(matrix: originFromScan) }
            if !voids.isEmpty { cells.values.filter { $0.record.owner == owner }.forEach(display) }
        }
        guard drifting != anchors[owner]!.drifting else { return }
        anchors[owner]!.drifting = drifting
        recoverLive()
        recount()
    }

    private func release(_ key: CellKey) {
        let remaining = (coverCounts[key] ?? 0) - 1
        if remaining > 0 {
            coverCounts[key] = remaining
        } else {
            coverCounts[key] = nil
            cells[key]?.occluder.isEnabled = true
        }
    }

    private func freeze(_ patch: Patch) {
        if isAligned {
            commit(patch)
        } else {
            patch.wireframe.model?.materials = [rememberedMaterial]
            pendingFreeze.append(patch)
        }
    }

    private func commit(_ patch: Patch) {
        for key in patch.hiding { release(key) }
        writeCells(from: patch)
        patch.occluder.removeFromParent()
    }

    /// Bins the chunk into cells owned by the pin nearest each cell, tracked or not, expressed
    /// through that pin's corrected estimate of the scan frame, and merges each with what the cell
    /// already holds. A cell moving to another pin has its old geometry carried over to the new
    /// pin's frame first, so it stays where it was drawn.
    private func writeCells(from patch: Patch) {
        guard let originFromScan = originFromScan(near: patch.position), let box = ScanGrid.bounds(of: patch.geometry) else { return }
        let scanFromPatch = originFromScan.inverse * patch.originFromPatch
        for (key, part) in ScanGrid.bin(patch.geometry, scanFromGeometry: Self.columns(scanFromPatch)) {
            guard let owner = nearestPin(toScan: key.center), let ownerOriginFromScan = self.originFromScan(for: owner) else { continue }
            let ownerScanFromPatch = ownerOriginFromScan.inverse * patch.originFromPatch
            let fresh = ScanGrid.transformed(part, by: Self.columns(ownerScanFromPatch))
            let geometry = cells[key].map { cell in
                var old = cell.record.geometry
                if cell.record.owner != owner, let previous = self.originFromScan(for: cell.record.owner) {
                    old = ScanGrid.transformed(old, by: Self.columns(ownerOriginFromScan.inverse * previous))
                }
                return ScanGrid.merged(old: old, replacingInside: box, boxFromOld: Self.columns(ownerScanFromPatch.inverse), with: fresh)
            } ?? fresh
            let record = ScanCellRecord(owner: owner, geometry: geometry)
            setCell(key, record)
            ScanStore.save(record, key: key)
        }
    }

    private func setCell(_ key: CellKey, _ record: ScanCellRecord) {
        cells[key]?.occluder.removeFromParent()
        cells[key] = nil
        guard let group = anchors[record.owner]?.group, let mesh = Self.mesh(record.geometry) else { return }
        let (occluder, wireframe) = makeEntities(parent: group)
        occluder.isEnabled = coverCounts[key] == nil
        let cell = Cell(occluder: occluder, wireframe: wireframe, mesh: mesh, record: record)
        display(cell)
        cells[key] = cell
    }

    // MARK: Void cut

    private func display(_ patch: Patch, material: UnlitMaterial) {
        display(patch.mesh, patch.geometry, on: patch.occluder, patch.wireframe, material: material)
    }

    private func display(_ cell: Cell) {
        display(cell.mesh, cell.record.geometry, on: cell.occluder, cell.wireframe, material: rememberedMaterial)
    }

    /// Shows `full` minus the triangles whose centre lies inside a void. Most meshes touch no void's
    /// box and are shown whole, so the common case is one box test per mesh.
    private func display(_ full: MeshResource, _ geometry: ScanGeometry, on occluder: ModelEntity, _ wireframe: ModelEntity, material: UnlitMaterial) {
        let worldFromLocal = occluder.transformMatrix(relativeTo: nil)
        let bounds = full.bounds.transformed(by: worldFromLocal)
        let hits = voids.filter { worldBox(of: $0).intersects(bounds) }
        var mesh: MeshResource? = full
        if !hits.isEmpty {
            let modelFromLocal = simd_inverse(worldFromModel) * worldFromLocal
            let positions = ScanGrid.positions(geometry.vertices)
            let indices = ScanGrid.indices(geometry.indices)
            var kept: [UInt32] = []
            kept.reserveCapacity(indices.count)
            for t in stride(from: 0, to: indices.count - 2, by: 3) {
                let centre = (positions[Int(indices[t])] + positions[Int(indices[t + 1])] + positions[Int(indices[t + 2])]) / 3
                let m = modelFromLocal * SIMD4(centre, 1)
                let p = SIMD3(m.x, m.y, m.z)
                if !hits.contains(where: { $0.contains(p) }) { kept.append(contentsOf: indices[t..<t + 3]) }
            }
            mesh = Self.mesh(ScanGeometry(vertices: geometry.vertices, indices: ScanGrid.packed(kept)))
        } else if occluder.model?.mesh === full {
            return
        }
        guard let mesh else {
            occluder.components.remove(ModelComponent.self)
            wireframe.components.remove(ModelComponent.self)
            return
        }
        occluder.model = ModelComponent(mesh: mesh, materials: [OcclusionMaterial()])
        wireframe.model = ModelComponent(mesh: mesh, materials: [material])
    }

    /// World box of a void: its plan outline up to its ceiling, open downward. Placement is
    /// yaw and uniform scale only, so world y depends on model y alone.
    private func worldBox(of void: Footprint.Void) -> BoundingBox {
        let corners = void.outline.map { p -> SIMD3<Float> in
            let w = worldFromModel * SIMD4(p.x, void.ceiling, p.z, 1)
            return SIMD3(w.x, w.y, w.z)
        }
        guard let first = corners.first else { return BoundingBox() }
        let lo = corners.reduce(first, simd_min)
        let hi = corners.reduce(first, simd_max)
        return BoundingBox(min: SIMD3(lo.x, -.greatestFiniteMagnitude, lo.z), max: hi)
    }

    private func makeGroup() -> Entity {
        let group = Entity()
        group.name = "scanPin"
        rememberedRoot.addChild(group)
        return group
    }

    private func makePatch(mesh: MeshResource) -> Patch {
        let (occluder, wireframe) = makeEntities(parent: liveRoot)
        return Patch(occluder: occluder, wireframe: wireframe, mesh: mesh)
    }

    private func makeEntities(parent: Entity) -> (occluder: ModelEntity, wireframe: ModelEntity) {
        let occluder = ModelEntity()
        let wireframe = ModelEntity()
        wireframe.isEnabled = isVisible
        occluder.addChild(wireframe)
        parent.addChild(occluder)
        return (occluder, wireframe)
    }

    /// Counts cells, so a live chunk over remembered cells is not counted twice and freezing it into
    /// them does not drop the count; a chunk not yet placed on the grid counts as one.
    private func recount() {
        let keys = live.values.reduce(into: Set(cells.keys)) { $0.formUnion($1.covering) }
        patchCount = keys.count + pendingFreeze.count + live.values.filter { $0.covering.isEmpty }.count
        rememberedCount = cells.count
    }

    private static func mesh(_ geometry: ScanGeometry) -> MeshResource? {
        guard !geometry.isEmpty else { return nil }
        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffer(ScanGrid.positions(geometry.vertices))
        descriptor.primitives = .triangles(ScanGrid.indices(geometry.indices))
        return try? MeshResource.generate(from: [descriptor])
    }

    // MARK: Geometry packing (float32 xyz triples; uint32 indices, three per triangle)

    private static func packed(_ source: GeometrySource) -> Data {
        let base = source.buffer.contents().advanced(by: source.offset)
        var data = Data(count: source.count * 3 * MemoryLayout<Float>.stride)
        data.withUnsafeMutableBytes { out in
            let dst = out.bindMemory(to: Float.self)
            for i in 0..<source.count {
                let v = base.advanced(by: i * source.stride).assumingMemoryBound(to: Float.self)
                dst[i * 3] = v[0]
                dst[i * 3 + 1] = v[1]
                dst[i * 3 + 2] = v[2]
            }
        }
        return data
    }

    private static func packed(_ element: GeometryElement) -> Data {
        let base = element.buffer.contents()
        let count = element.count * 3
        var data = Data(count: count * MemoryLayout<UInt32>.stride)
        data.withUnsafeMutableBytes { out in
            let dst = out.bindMemory(to: UInt32.self)
            for i in 0..<count {
                let p = base.advanced(by: i * element.bytesPerIndex)
                dst[i] = element.bytesPerIndex == 2
                    ? UInt32(p.assumingMemoryBound(to: UInt16.self).pointee)
                    : p.assumingMemoryBound(to: UInt32.self).pointee
            }
        }
        return data
    }

    private nonisolated static func translation(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    private nonisolated static func transformed(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let q = m * SIMD4(p, 1)
        return SIMD3(q.x, q.y, q.z)
    }

    /// Column-major packing of a 4×4 matrix, as saved in `ScanAnchorRecord` and `Placement`.
    static func columns(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    static func matrix(_ v: [Float]) -> simd_float4x4 {
        guard v.count == 16 else { return matrix_identity_float4x4 }
        return simd_float4x4(
            SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]),
            SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15]))
    }
}
