import ARKit
import Metal
import RealityKit

/// Scene-reconstruction geometry, kept for the whole property. ARKit only maintains mesh anchors
/// near the wearer and reports the rest as removed; a removed chunk is binned into 1 m cells of a
/// project-wide scan frame and saved. The scan frame is pinned to the room by world anchors spaced
/// through the property; each cell is placed by the pin that owns it, so the scan is back as soon
/// as visionOS recognises any one pin, and a live chunk only hides the cells it has triangles in.
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
        var geometry = ScanGeometry()
        var originFromPatch = matrix_identity_float4x4
        var covering: Set<CellKey> = []

        var position: SIMD3<Float> { ScanMesh.translation(originFromPatch) }
    }

    private struct Cell {
        let occluder: ModelEntity
        let wireframe: ModelEntity
        let record: ScanCellRecord
    }

    private struct Anchor {
        let scanFromAnchor: simd_float4x4
        var originFromAnchor: simd_float4x4?
        let group: Entity
    }

    private var project: String?
    private let liveRoot = Entity()
    private let rememberedRoot = Entity()
    private var live: [UUID: Patch] = [:]
    private var pendingFreeze: [Patch] = []
    private var cells: [CellKey: Cell] = [:]
    private var anchors: [UUID: Anchor] = [:]
    private var coverCounts: [CellKey: Int] = [:]

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
            var patch = live[anchor.id] ?? makePatch()
            patch.occluder.model = ModelComponent(mesh: mesh, materials: [OcclusionMaterial()])
            patch.wireframe.model = ModelComponent(mesh: mesh, materials: [liveMaterial])
            patch.originFromPatch = anchor.originFromAnchorTransform
            patch.occluder.transform = Transform(matrix: patch.originFromPatch)
            patch.geometry = ScanGeometry(vertices: Self.packed(anchor.geometry.vertices), indices: Self.packed(anchor.geometry.faces))
            cover(&patch)
            live[anchor.id] = patch
        case .removed:
            guard let patch = live.removeValue(forKey: anchor.id) else { return }
            freeze(patch)
        }
        recount()
    }

    /// Freezes every live patch; called when the immersive space closes or the project changes.
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

    // MARK: Pins

    var anchorIDs: [UUID] { Array(anchors.keys) }

    func hasAnchor(_ id: UUID) -> Bool { anchors[id] != nil }

    /// Session-origin positions of every pin: tracked ones where visionOS reports them, the rest
    /// estimated through the nearest tracked pin. Empty while nothing is tracked.
    var anchorPositions: [SIMD3<Float>] {
        anchors.values.compactMap { anchor in
            if let originFromAnchor = anchor.originFromAnchor { return Self.translation(originFromAnchor) }
            guard let via = nearestTracked(toScan: Self.translation(anchor.scanFromAnchor)) else { return nil }
            return Self.translation(originFromScan(via: via) * anchor.scanFromAnchor)
        }
    }

    func originFromScan(near position: SIMD3<Float>) -> simd_float4x4? {
        nearestTracked(toOrigin: position).map(originFromScan(via:))
    }

    func addAnchor(id: UUID, scanFromAnchor: simd_float4x4, originFromAnchor: simd_float4x4) {
        anchors[id] = Anchor(scanFromAnchor: scanFromAnchor, originFromAnchor: originFromAnchor, group: makeGroup())
        if let project {
            ScanStore.saveAnchors(
                anchors.map { ScanAnchorRecord(id: $0.key, scanFromAnchor: Self.columns($0.value.scanFromAnchor)) },
                project: project)
        }
        refreshAlignment()
    }

    func anchorUpdated(_ id: UUID, originFromAnchor: simd_float4x4, tracked: Bool) {
        guard anchors[id] != nil else { return }
        anchors[id]?.originFromAnchor = tracked ? originFromAnchor : nil
        refreshAlignment()
    }

    // MARK: Project

    func load(project: String, anchors: [ScanAnchorRecord], cells: [CellKey: ScanCellRecord]) {
        self.project = project
        removeAll()
        for record in anchors {
            self.anchors[record.id] = Anchor(scanFromAnchor: Self.matrix(record.scanFromAnchor), originFromAnchor: nil, group: makeGroup())
        }
        for (key, record) in cells { setCell(key, record) }
        recount()
    }

    func clear() {
        removeAll()
        recount()
    }

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
    /// of the scan frame. Gaining the first tracked pin commits what was frozen without one.
    private func refreshAlignment() {
        let aligned = anchors.values.contains { $0.originFromAnchor != nil }
        for (id, anchor) in anchors {
            let via = anchor.originFromAnchor != nil ? id : nearestTracked(toScan: Self.translation(anchor.scanFromAnchor))
            if let via { anchor.group.transform = Transform(matrix: originFromScan(via: via)) }
        }
        rememberedRoot.isEnabled = aligned
        let wasAligned = isAligned
        isAligned = aligned
        guard aligned != wasAligned else { return }
        if aligned {
            for id in live.keys {
                var patch = live[id]!
                cover(&patch)
                live[id] = patch
            }
            for patch in pendingFreeze { commit(patch) }
            pendingFreeze.removeAll()
        } else {
            for id in live.keys { live[id]?.covering = [] }
            coverCounts.removeAll()
            cells.values.forEach { $0.occluder.isEnabled = true }
        }
        recount()
    }

    private func originFromScan(via id: UUID) -> simd_float4x4 {
        let anchor = anchors[id]!
        return anchor.originFromAnchor! * anchor.scanFromAnchor.inverse
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

    private func cover(_ patch: inout Patch) {
        guard let originFromScan = originFromScan(near: patch.position) else { return }
        let keys = ScanGrid.keys(of: patch.geometry, scanFromGeometry: Self.columns(originFromScan.inverse * patch.originFromPatch))
        for key in patch.covering.subtracting(keys) { release(key) }
        for key in keys.subtracting(patch.covering) {
            coverCounts[key, default: 0] += 1
            cells[key]?.occluder.isEnabled = false
        }
        patch.covering = keys
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
        for key in patch.covering { release(key) }
        writeCells(from: patch)
        patch.occluder.removeFromParent()
    }

    /// Bins the chunk into cells owned by the tracked pin nearest each cell, expressed through that
    /// pin's estimate of the scan frame, and merges each with what the cell already holds.
    private func writeCells(from patch: Patch) {
        guard let nearest = nearestTracked(toOrigin: patch.position), let box = ScanGrid.bounds(of: patch.geometry) else { return }
        let scanFromPatch = originFromScan(via: nearest).inverse * patch.originFromPatch
        for (key, part) in ScanGrid.bin(patch.geometry, scanFromGeometry: Self.columns(scanFromPatch)) {
            let owner = nearestTracked(toScan: key.center) ?? nearest
            let ownerScanFromPatch = originFromScan(via: owner).inverse * patch.originFromPatch
            let fresh = ScanGrid.transformed(part, by: Self.columns(ownerScanFromPatch))
            let geometry = cells[key].map {
                ScanGrid.merged(old: $0.record.geometry, replacingInside: box, boxFromOld: Self.columns(ownerScanFromPatch.inverse), with: fresh)
            } ?? fresh
            let record = ScanCellRecord(owner: owner, geometry: geometry)
            setCell(key, record)
            if let project { ScanStore.save(record, key: key, project: project) }
        }
    }

    private func setCell(_ key: CellKey, _ record: ScanCellRecord) {
        cells[key]?.occluder.removeFromParent()
        cells[key] = nil
        guard let group = anchors[record.owner]?.group, let mesh = Self.mesh(record.geometry) else { return }
        let (occluder, wireframe) = makeEntities(parent: group)
        occluder.model = ModelComponent(mesh: mesh, materials: [OcclusionMaterial()])
        wireframe.model = ModelComponent(mesh: mesh, materials: [rememberedMaterial])
        occluder.isEnabled = coverCounts[key] == nil
        cells[key] = Cell(occluder: occluder, wireframe: wireframe, record: record)
    }

    private func makeGroup() -> Entity {
        let group = Entity()
        group.name = "scanPin"
        rememberedRoot.addChild(group)
        return group
    }

    private func makePatch() -> Patch {
        let (occluder, wireframe) = makeEntities(parent: liveRoot)
        return Patch(occluder: occluder, wireframe: wireframe)
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

    private static func columns(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    private static func matrix(_ v: [Float]) -> simd_float4x4 {
        guard v.count == 16 else { return matrix_identity_float4x4 }
        return simd_float4x4(
            SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]),
            SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15]))
    }
}
