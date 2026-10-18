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
    private(set) var isAligned = false

    private struct Patch {
        let id: UUID
        let occluder: ModelEntity
        let wireframe: ModelEntity
        var vertices = Data()
        var indices = Data()
    }

    private var project: String?
    private let liveRoot = Entity()
    private let anchored = Entity()
    private var live: [UUID: Patch] = [:]
    private var remembered: [Patch] = []
    private var pendingFreeze: [Patch] = []

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
            var patch = live[anchor.id] ?? makePatch(parent: liveRoot)
            patch.occluder.model = ModelComponent(mesh: mesh, materials: [OcclusionMaterial()])
            patch.wireframe.model = ModelComponent(mesh: mesh, materials: [liveMaterial])
            patch.occluder.transform = Transform(matrix: anchor.originFromAnchorTransform)
            patch.vertices = Self.packed(anchor.geometry.vertices)
            patch.indices = Self.packed(anchor.geometry.faces)
            live[anchor.id] = patch
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
        isAligned = true
        for patch in pendingFreeze { attachRemembered(patch) }
        pendingFreeze.removeAll()
        recount()
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
            var patch = makePatch(parent: anchored, id: stored.id)
            patch.occluder.model = ModelComponent(mesh: mesh, materials: [OcclusionMaterial()])
            patch.wireframe.model = ModelComponent(mesh: mesh, materials: [rememberedMaterial])
            patch.occluder.transform = Transform(matrix: Self.matrix(stored.transform))
            patch.vertices = stored.vertices
            patch.indices = stored.indices
            remembered.append(patch)
        }
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
        let bounds = patch.occluder.visualBounds(relativeTo: nil)
        remembered.removeAll { candidate in
            let center = candidate.occluder.visualBounds(relativeTo: nil).center
            guard bounds.contains(center) else { return false }
            candidate.occluder.removeFromParent()
            if let project { ScanStore.remove(id: candidate.id, project: project) }
            return true
        }
    }

    private func makePatch(parent: Entity, id: UUID = UUID()) -> Patch {
        let occluder = ModelEntity()
        let wireframe = ModelEntity()
        wireframe.isEnabled = isVisible
        occluder.addChild(wireframe)
        parent.addChild(occluder)
        return Patch(id: id, occluder: occluder, wireframe: wireframe)
    }

    private func recount() {
        patchCount = live.count + remembered.count + pendingFreeze.count
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

    private static func unpacked<T>(_ data: Data, as: T.Type) -> [T] {
        data.withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
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
