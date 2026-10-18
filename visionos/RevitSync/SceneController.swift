import ARKit
import Foundation
import QuartzCore
import RealityKit
import simd

struct Placement: Codable, Equatable {
    var position: SIMD3<Float>
    var yaw: Float
    var scale: Float
    var anchorID: UUID?

    static let tabletop = Placement(position: [0, 0.8, -1.0], yaw: 0, scale: ScalePreset.fiftieth.rawValue)
}

enum ScalePreset: Float, CaseIterable, Identifiable {
    case full = 1
    case twentieth = 0.05
    case fiftieth = 0.02
    case hundredth = 0.01

    var id: Float { rawValue }
    var label: String {
        switch self {
        case .full: "1:1"
        case .twentieth: "1:20"
        case .fiftieth: "1:50"
        case .hundredth: "1:100"
        }
    }
}

@MainActor
@Observable
final class SceneController {
    let root = Entity()
    let model = Entity()
    let handle: ModelEntity
    let scanMesh = ScanMesh()

    private(set) var placement = Placement.tabletop
    private(set) var project: String?
    private var partitions: [String: (sha256: String, entity: Entity)] = [:]
    var isGesturing = false

    var loadedPartitions: [String: String] { partitions.mapValues(\.sha256) }

    private let session = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private let sceneReconstruction = SceneReconstructionProvider()
    private var trackingTask: Task<Void, Never>?

    init() {
        handle = ModelEntity(
            mesh: .generateSphere(radius: 0.035),
            materials: [SimpleMaterial(color: .systemBlue, roughness: 0.3, isMetallic: false)])
        handle.name = "handle"
        handle.position = [0, 1.2, 0]
        handle.generateCollisionShapes(recursive: false)

        root.name = "root"
        root.components.set(InputTargetComponent())
        root.components.set(CollisionComponent(shapes: [.generateBox(size: [0.2, 0.2, 0.2])]))
        root.addChild(model)
        root.addChild(handle)
        applyPlacement()
    }

    // MARK: Partitions

    func activate(project: String) {
        guard self.project != project else { return }
        self.project = project
        clear()
        placement = Placement.load(project: project) ?? .tabletop
        applyPlacement()
    }

    func replace(partitionID: String, sha256: String, fileURL: URL) async throws {
        let entity = try await Entity(contentsOf: fileURL)
        entity.name = partitionID
        partitions[partitionID]?.entity.removeFromParent()
        partitions[partitionID] = (sha256, entity)
        model.addChild(entity)
        refreshCollision()
    }

    func remove(partitionID: String) {
        partitions[partitionID]?.entity.removeFromParent()
        partitions[partitionID] = nil
        refreshCollision()
    }

    func clear() {
        partitions.values.forEach { $0.entity.removeFromParent() }
        partitions.removeAll()
        refreshCollision()
    }

    var partitionCount: Int { partitions.count }

    private func refreshCollision() {
        let bounds = model.visualBounds(relativeTo: root)
        let extents = simd_max(bounds.extents, SIMD3<Float>(repeating: 0.2))
        root.components.set(CollisionComponent(shapes: [
            .generateBox(size: extents).offsetBy(translation: bounds.center)
        ]))
    }

    // MARK: Placement

    func setLocked(_ locked: Bool) {
        handle.isEnabled = !locked
        root.components[InputTargetComponent.self]?.isEnabled = !locked
    }

    func setPosition(_ position: SIMD3<Float>) {
        placement.position = position
        applyPlacement()
    }

    func setYaw(_ yaw: Float) {
        placement.yaw = yaw
        applyPlacement()
    }

    func setScale(_ scale: Float) {
        placement.scale = min(max(scale, 0.001), 2)
        applyPlacement()
    }

    func placeInFrontOfUser() {
        var position = SIMD3<Float>(0, 0, -1.5)
        var yaw: Float = 0
        if let pose = devicePose() {
            let origin = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
            var forward = -SIMD3<Float>(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
            forward.y = 0
            if simd_length(forward) > 0.001 { forward = simd_normalize(forward) } else { forward = [0, 0, -1] }
            let distance: Float = placement.scale >= 0.5 ? 1.5 : 1.0
            position = origin + forward * distance
            yaw = atan2(forward.x, forward.z) + .pi
        }
        position.y = placement.scale >= 0.5 ? 0 : 0.8
        placement.position = position
        placement.yaw = yaw
        applyPlacement()
        commitPlacement()
    }

    func commitPlacement() {
        guard let project else { return }
        placement.save(project: project)
        Task { await pinWorldAnchor() }
    }

    private func applyPlacement() {
        root.position = placement.position
        root.orientation = simd_quatf(angle: placement.yaw, axis: [0, 1, 0])
        root.scale = SIMD3<Float>(repeating: placement.scale)
        handle.scale = SIMD3<Float>(repeating: 1 / placement.scale)
    }

    // MARK: World tracking

    func startTracking() {
        guard trackingTask == nil, WorldTrackingProvider.isSupported else { return }
        let reconstructs = SceneReconstructionProvider.isSupported
        let providers: [any DataProvider] = reconstructs ? [worldTracking, sceneReconstruction] : [worldTracking]
        trackingTask = Task {
            do {
                try await session.run(providers)
            } catch {
                return
            }
            if reconstructs {
                Task {
                    for await update in sceneReconstruction.anchorUpdates {
                        await scanMesh.apply(update)
                    }
                }
            }
            for await update in worldTracking.anchorUpdates {
                if case .removed = update.event { continue }
                guard update.anchor.id == placement.anchorID, update.anchor.isTracked, !isGesturing else { continue }
                let m = update.anchor.originFromAnchorTransform
                placement.position = [m.columns.3.x, m.columns.3.y, m.columns.3.z]
                placement.yaw = atan2(m.columns.2.x, m.columns.2.z)
                applyPlacement()
            }
        }
    }

    private func devicePose() -> simd_float4x4? {
        guard worldTracking.state == .running else { return nil }
        return worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())?.originFromAnchorTransform
    }

    private func pinWorldAnchor() async {
        guard worldTracking.state == .running, let project else { return }
        let old = placement.anchorID
        placement.anchorID = nil
        var transform = matrix_identity_float4x4
        let rotation = simd_float3x3(simd_quatf(angle: placement.yaw, axis: [0, 1, 0]))
        transform.columns.0 = SIMD4(rotation.columns.0, 0)
        transform.columns.1 = SIMD4(rotation.columns.1, 0)
        transform.columns.2 = SIMD4(rotation.columns.2, 0)
        transform.columns.3 = SIMD4(placement.position, 1)
        let anchor = WorldAnchor(originFromAnchorTransform: transform)
        if let old {
            try? await worldTracking.removeAnchor(forID: old)
        }
        do {
            try await worldTracking.addAnchor(anchor)
            placement.anchorID = anchor.id
        } catch {
            placement.anchorID = nil
        }
        placement.save(project: project)
    }
}

extension Placement {
    private static func key(_ project: String) -> String { "placement.\(project)" }

    static func load(project: String) -> Placement? {
        guard let data = UserDefaults.standard.data(forKey: key(project)) else { return nil }
        return try? JSONDecoder().decode(Placement.self, from: data)
    }

    func save(project: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key(project))
    }
}
