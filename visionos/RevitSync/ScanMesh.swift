import ARKit
import Metal
import RealityKit

/// Scene-reconstruction patches, kept for the whole property. ARKit only maintains mesh anchors
/// near the wearer and reports the rest as removed; removed patches are frozen under `anchored`
/// (which follows the project's scan world anchor) and saved, so they survive walking away and
/// relaunching. A new live patch covering a frozen one replaces it.
@MainActor
@Observable
final class ScanMesh {
    let root = Entity()

    var isVisible = false {
        didSet {
            live.values.forEach { $0.wireframe.isEnabled = isVisible }
            remembered.forEach { $0.wireframe.isEnabled = isVisible }
            pendingFreeze.forEach { $0.wireframe.isEnabled = isVisible }
        }
    }

    private(set) var patchCount = 0
    private(set) var rememberedCount = 0
    private(set) var isAligned = false

    /// `vertices`/`indices`/`mesh` are the full patch, which is what `ScanStore` saves; the occluder
    /// and wireframe display it minus the triangles inside model voids.
    private struct Patch {
        let id: UUID
        let occluder: ModelEntity
        let wireframe: ModelEntity
        var mesh: MeshResource
        var vertices = Data()
        var indices = Data()
    }

    private var project: String?
    private let liveRoot = Entity()
    private let anchored = Entity()
    private var live: [UUID: Patch] = [:]
    private var remembered: [Patch] = []
    private var pendingFreeze: [Patch] = []
    private var voids: [Footprint.Void] = []
    private var worldFromModel = matrix_identity_float4x4
    private var recutTask: Task<Void, Never>?

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
        anchored.name = "scanAnchored"
        anchored.isEnabled = false
        root.addChild(liveRoot)
        root.addChild(anchored)
    }

    // MARK: Live updates

    func apply(_ update: AnchorUpdate<MeshAnchor>) async {
        let anchor = update.anchor
        switch update.event {
        case .added, .updated:
            guard let mesh = try? await MeshResource(from: anchor) else { return }
            let isNew = live[anchor.id] == nil
            var patch = live[anchor.id] ?? makePatch(parent: liveRoot, mesh: mesh)
            patch.mesh = mesh
            patch.occluder.transform = Transform(matrix: anchor.originFromAnchorTransform)
            patch.vertices = Self.packed(anchor.geometry.vertices)
            patch.indices = Self.packed(anchor.geometry.faces)
            live[anchor.id] = patch
            recut([patch])
            if isNew { replaceRemembered(coveredBy: patch) }
        case .removed:
            guard let patch = live.removeValue(forKey: anchor.id) else { return }
            freeze(patch)
        }
        recount()
    }

    /// Freezes every live patch; called when the immersive space closes so nothing is lost.
    func flushLive() {
        for patch in live.values { freeze(patch) }
        live.removeAll()
        recount()
    }

    // MARK: Anchor

    func setAnchorTransform(_ transform: simd_float4x4) {
        anchored.transform = Transform(matrix: transform)
        anchored.isEnabled = true
        let wasAligned = isAligned
        isAligned = true
        if !wasAligned {
            // Remembered patches only have a world position from here on; compare everything
            // scanned so far against them, then freeze what was waiting for the anchor.
            for patch in live.values { replaceRemembered(coveredBy: patch) }
            for patch in pendingFreeze { replaceRemembered(coveredBy: patch) }
        }
        for patch in pendingFreeze { attachRemembered(patch) }
        pendingFreeze.removeAll()
        if !wasAligned { recut(remembered) }
        recount()
    }

    // MARK: Model voids

    func setVoids(_ voids: [Footprint.Void], worldFromModel: simd_float4x4) {
        self.voids = voids
        self.worldFromModel = worldFromModel
        recut(Array(live.values) + remembered + pendingFreeze)
    }

    // MARK: Project

    func load(project: String, patches: [ScanPatch]) {
        self.project = project
        removeAll()
        for stored in patches {
            var descriptor = MeshDescriptor()
            descriptor.positions = MeshBuffer(Self.positions(stored.vertices))
            descriptor.primitives = .triangles(Self.unpacked(stored.indices, as: UInt32.self))
            guard let mesh = try? MeshResource.generate(from: [descriptor]) else { continue }
            var patch = makePatch(parent: anchored, id: stored.id, mesh: mesh)
            patch.occluder.transform = Transform(matrix: Self.matrix(stored.transform))
            patch.vertices = stored.vertices
            patch.indices = stored.indices
            remembered.append(patch)
        }
        recut(remembered)
        recount()
    }

    func clear() {
        removeAll()
        recount()
    }

    // MARK: Internals

    private func removeAll() {
        live.values.forEach { $0.occluder.removeFromParent() }
        remembered.forEach { $0.occluder.removeFromParent() }
        pendingFreeze.forEach { $0.occluder.removeFromParent() }
        live.removeAll()
        remembered.removeAll()
        pendingFreeze.removeAll()
        anchored.isEnabled = false
        isAligned = false
    }

    private func freeze(_ patch: Patch) {
        patch.wireframe.model?.materials = [rememberedMaterial]
        if isAligned {
            attachRemembered(patch)
        } else {
            pendingFreeze.append(patch)
        }
    }

    private func attachRemembered(_ patch: Patch) {
        patch.occluder.setParent(anchored, preservingWorldTransform: true)
        remembered.append(patch)
        guard let project else { return }
        ScanStore.save(
            ScanPatch(id: patch.id, transform: Self.columns(patch.occluder.transform.matrix),
                      vertices: patch.vertices, indices: patch.indices),
            project: project)
    }

    /// ARKit tiles space into fixed chunks, so a new live patch whose bounds contain a remembered
    /// patch's centre is the same chunk scanned again: the remembered copy and its file go away,
    /// and the live patch is saved in its place when it is frozen.
    private func replaceRemembered(coveredBy patch: Patch) {
        guard isAligned else { return }
        let bounds = worldBounds(patch)
        remembered.removeAll { candidate in
            let center = worldBounds(candidate).center
            guard bounds.contains(center) else { return false }
            candidate.occluder.removeFromParent()
            if let project { ScanStore.remove(id: candidate.id, project: project) }
            return true
        }
    }

    private func makePatch(parent: Entity, id: UUID = UUID(), mesh: MeshResource) -> Patch {
        let occluder = ModelEntity()
        let wireframe = ModelEntity()
        wireframe.isEnabled = isVisible
        occluder.addChild(wireframe)
        parent.addChild(occluder)
        return Patch(id: id, occluder: occluder, wireframe: wireframe, mesh: mesh)
    }

    /// Full-geometry bounds, so a patch cut down to nothing still has a place in the world.
    private func worldBounds(_ patch: Patch) -> BoundingBox {
        patch.mesh.bounds.transformed(by: patch.occluder.transformMatrix(relativeTo: nil))
    }

    private func recut(_ patches: [Patch]) {
        recutTask = Task { [previous = recutTask] in
            await previous?.value
            for patch in patches { cut(patch) }
        }
    }

    private func cut(_ patch: Patch) {
        let isLive = live.values.contains { $0.occluder === patch.occluder }
        let wireframeMaterial = isLive ? liveMaterial : rememberedMaterial
        let patchBounds = worldBounds(patch)
        let modelFromWorld = simd_inverse(worldFromModel)
        let hits = voids.filter { void in
            guard let first = void.outline.first else { return false }
            let world = void.outline.map { worldFromModel * SIMD4($0, 1) }
            let xs = world.map(\.x), zs = world.map(\.z)
            // Placement is yaw-only, so world y depends on model y alone.
            let top = (worldFromModel * SIMD4(first.x, void.ceiling, first.z, 1)).y
            let box = BoundingBox(
                min: SIMD3<Float>(xs.min()!, -.greatestFiniteMagnitude, zs.min()!),
                max: SIMD3<Float>(xs.max()!, top, zs.max()!))
            return box.intersects(patchBounds)
        }

        var mesh = patch.mesh
        if !hits.isEmpty {
            let positions = Self.positions(patch.vertices)
            let indices = Self.unpacked(patch.indices, as: UInt32.self)
            let modelFromLocal = modelFromWorld * patch.occluder.transformMatrix(relativeTo: nil)
            var kept: [UInt32] = []
            kept.reserveCapacity(indices.count)
            for t in stride(from: 0, to: indices.count - 2, by: 3) {
                let tri = indices[t..<t + 3]
                let centre = tri.reduce(SIMD3<Float>.zero) { $0 + positions[Int($1)] } / 3
                let m = modelFromLocal * SIMD4(centre, 1)
                let p = SIMD3(m.x, m.y, m.z)
                if !hits.contains(where: { $0.contains(p) }) { kept.append(contentsOf: tri) }
            }
            guard !kept.isEmpty else {
                patch.occluder.components.remove(ModelComponent.self)
                patch.wireframe.components.remove(ModelComponent.self)
                return
            }
            var descriptor = MeshDescriptor()
            descriptor.positions = MeshBuffer(positions)
            descriptor.primitives = .triangles(kept)
            guard let generated = try? MeshResource.generate(from: [descriptor]) else { return }
            mesh = generated
        }
        patch.occluder.model = ModelComponent(mesh: mesh, materials: [OcclusionMaterial()])
        patch.wireframe.model = ModelComponent(mesh: mesh, materials: [wireframeMaterial])
    }

    private func recount() {
        patchCount = live.count + remembered.count + pendingFreeze.count
        rememberedCount = remembered.count
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

    private static func positions(_ data: Data) -> [SIMD3<Float>] {
        let floats = unpacked(data, as: Float.self)
        return stride(from: 0, to: floats.count - 2, by: 3).map { SIMD3(floats[$0], floats[$0 + 1], floats[$0 + 2]) }
    }

    // Bytes decoded from a property list carry no alignment guarantee, so read them unaligned.
    private static func unpacked<T>(_ data: Data, as: T.Type) -> [T] {
        let size = MemoryLayout<T>.stride
        return data.withUnsafeBytes { bytes in
            (0..<(bytes.count / size)).map { bytes.loadUnaligned(fromByteOffset: $0 * size, as: T.self) }
        }
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
