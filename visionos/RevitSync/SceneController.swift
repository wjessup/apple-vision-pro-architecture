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

enum PlacementMode: String, CaseIterable, Identifiable {
    case basic
    case precise

    var id: String { rawValue }
    var label: String {
        switch self {
        case .basic: "Basic"
        case .precise: "Precise"
        }
    }
}

@MainActor
@Observable
final class SceneController {
    let root = Entity()
    let model = Entity()
    let handle: ModelEntity
    let pivotMarker: ModelEntity
    let scanMesh = ScanMesh()
    let measureRoot = Entity()

    private(set) var placement = Placement.tabletop
    private(set) var mode = PlacementMode.basic
    private var pinTask: Task<Void, Never>?
    private(set) var project: String?
    private var partitions: [String: (sha256: String, entity: Entity)] = [:]
    var isGesturing = false

    private(set) var measuring = false
    private(set) var preparingMeasure = false
    private(set) var measurements: [Measurement] = []
    private(set) var pendingPoint: SIMD3<Float>?
    var selectedMeasurement: UUID?
    private var locked = false
    private var meshShapes: [String: Task<[(entity: Entity, shape: ShapeResource)], Never>] = [:]
    private var measureEntities: [UUID: Entity] = [:]
    private let pendingDot: ModelEntity
    private static let measureMaterial = UnlitMaterial(color: .systemYellow)
    private var panelPlaced = false
    private var panelMoving = false

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

        var ringMaterial = UnlitMaterial(color: .systemBlue)
        ringMaterial.blending = .transparent(opacity: 0.5)
        pivotMarker = ModelEntity(mesh: .generateCylinder(height: 0.002, radius: 0.25), materials: [ringMaterial])
        pivotMarker.name = "pivotMarker"
        pivotMarker.isEnabled = false

        pendingDot = ModelEntity(mesh: .generateSphere(radius: 0.01), materials: [Self.measureMaterial])

        root.name = "root"
        root.components.set(InputTargetComponent())
        root.addChild(model)
        root.addChild(handle)
        root.addChild(pivotMarker)

        pendingDot.isEnabled = false
        measureRoot.name = "measurements"
        measureRoot.addChild(pendingDot)
        root.addChild(measureRoot)
        refreshCollision()
        applyPlacement()
    }

    // MARK: Partitions

    func activate(project: String) {
        guard self.project != project else { return }
        self.project = project
        clear()
        placement = Placement.load(project: project) ?? .tabletop
        measurements = .load(project: project)
        setPending(nil)
        selectedMeasurement = nil
        redrawMeasurements()
        applyPlacement()
    }

    func replace(partitionID: String, sha256: String, fileURL: URL) async throws {
        let entity = try await Entity(contentsOf: fileURL)
        entity.name = partitionID
        partitions[partitionID]?.entity.removeFromParent()
        meshShapes[partitionID] = nil
        partitions[partitionID] = (sha256, entity)
        model.addChild(entity)
        await refreshCollisionAsync()
    }

    func remove(partitionID: String) {
        partitions[partitionID]?.entity.removeFromParent()
        partitions[partitionID] = nil
        meshShapes[partitionID] = nil
        refreshCollision()
    }

    func clear() {
        partitions.values.forEach { $0.entity.removeFromParent() }
        partitions.removeAll()
        meshShapes.removeAll()
        refreshCollision()
    }

    var partitionCount: Int { partitions.count }

    private func refreshCollision() {
        Task { await refreshCollisionAsync() }
    }

    // Measuring needs taps on the real surfaces, so each partition mesh gets an exact collider
    // instead of the whole-model box; the shapes are cached per partition load.
    private func refreshCollisionAsync() async {
        handle.isEnabled = !locked && !measuring
        if measuring {
            root.components.remove(CollisionComponent.self)
            for (id, partition) in partitions where meshShapes[id] == nil {
                meshShapes[id] = Task { await Self.staticShapes(for: partition.entity) }
            }
            let tasks = meshShapes
            preparingMeasure = true
            var ready: [[(entity: Entity, shape: ShapeResource)]] = []
            for task in tasks.values { ready.append(await task.value) }
            preparingMeasure = false
            guard measuring else { return }
            for shapes in ready {
                for (entity, shape) in shapes where entity.parent != nil {
                    entity.components.set(CollisionComponent(shapes: [shape], isStatic: true))
                }
            }
            return
        }
        for task in meshShapes.values {
            for (entity, _) in await task.value { entity.components.remove(CollisionComponent.self) }
        }
        guard !measuring else { return }
        guard mode == .basic else {
            root.components.remove(CollisionComponent.self)
            return
        }
        let bounds = model.visualBounds(relativeTo: root)
        let extents = simd_max(bounds.extents, SIMD3<Float>(repeating: 0.2))
        root.components.set(CollisionComponent(shapes: [
            .generateBox(size: extents).offsetBy(translation: bounds.center)
        ]))
    }

    // MARK: Placement

    func setLocked(_ locked: Bool) {
        self.locked = locked
        refreshCollision()
    }

    // MARK: Measurements

    func setMeasuring(_ measuring: Bool) {
        self.measuring = measuring
        if !measuring { setPending(nil) }
        refreshCollision()
    }

    func addMeasurePoint(_ point: SIMD3<Float>) {
        guard let start = pendingPoint else {
            setPending(point)
            return
        }
        measurements.append(Measurement(a: start, b: point))
        setPending(nil)
        saveMeasurements()
    }

    func deleteMeasurement(id: UUID) {
        measurements.removeAll { $0.id == id }
        if selectedMeasurement == id { selectedMeasurement = nil }
        saveMeasurements()
    }

    func labelAnchor(id: UUID) -> Entity? { measureEntities[id]?.findEntity(named: "label") }

    private func setPending(_ point: SIMD3<Float>?) {
        pendingPoint = point
        pendingDot.isEnabled = point != nil
        if let point { pendingDot.position = point }
    }

    private func saveMeasurements() {
        if let project { measurements.save(project: project) }
        redrawMeasurements()
    }

    private func redrawMeasurements() {
        measureEntities.values.forEach { $0.removeFromParent() }
        measureEntities.removeAll()
        for measurement in measurements {
            let layer = Entity()
            let line = ModelEntity(mesh: .generateCylinder(height: 1, radius: 0.003), materials: [Self.measureMaterial])
            let delta = measurement.b - measurement.a
            if measurement.meters > 0 { line.orientation = simd_quatf(from: [0, 1, 0], to: delta / measurement.meters) }
            layer.addChild(line)
            for _ in 0..<2 {
                layer.addChild(ModelEntity(mesh: .generateSphere(radius: 0.008), materials: [Self.measureMaterial]))
            }
            let label = Entity()
            label.name = "label"
            layer.addChild(label)
            measureRoot.addChild(layer)
            measureEntities[measurement.id] = layer
        }
        applyMeasureScale()
    }

    // Each measurement layer is counter-scaled so dots, lines and labels keep a constant real size;
    // positions inside it are therefore model coordinates multiplied by the model scale.
    private func applyMeasureScale() {
        let s = placement.scale
        pendingDot.scale = SIMD3<Float>(repeating: 1 / s)
        for measurement in measurements {
            guard let layer = measureEntities[measurement.id] else { continue }
            layer.scale = SIMD3<Float>(repeating: 1 / s)
            let children = Array(layer.children)
            let mid = (measurement.a + measurement.b) / 2 * s
            children[0].position = mid
            children[0].scale = [1, max(measurement.meters * s, 0.0001), 1]
            children[1].position = measurement.a * s
            children[2].position = measurement.b * s
            children[3].position = mid + [0, 0.04, 0]
        }
    }

    private static func staticShapes(for root: Entity) async -> [(entity: Entity, shape: ShapeResource)] {
        var shapes: [(entity: Entity, shape: ShapeResource)] = []
        for entity in meshEntities(in: root) {
            guard let mesh = entity.components[ModelComponent.self]?.mesh,
                  let shape = try? await ShapeResource.generateStaticMesh(from: mesh) else { continue }
            shapes.append((entity, shape))
        }
        return shapes
    }

    private static func meshEntities(in entity: Entity) -> [Entity] {
        var result = entity.components.has(ModelComponent.self) ? [entity] : []
        for child in entity.children { result += meshEntities(in: child) }
        return result
    }

    // MARK: Tools panel

    // Lazy follow: the panel stays put while it is roughly in front of the user and only eases
    // back once it has drifted out of view or reach, avoiding head-locked UI.
    func resetPanel() {
        panelPlaced = false
        panelMoving = false
    }

    func updatePanel(_ panel: Entity, deltaTime: Float, follow: Bool) {
        guard let pose = devicePose() else {
            if !panelPlaced { panel.position = [0, 1.1, -0.6] }
            return
        }
        let eye = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        var forward = -SIMD3<Float>(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
        forward.y = 0
        forward = simd_length(forward) > 0.001 ? simd_normalize(forward) : [0, 0, -1]
        let target = eye + forward * 0.6 + [0, -0.3, 0]
        let facing = simd_quatf(angle: atan2(forward.x, forward.z) + .pi, axis: [0, 1, 0])

        guard panelPlaced else {
            panel.position = target
            panel.orientation = facing
            panelPlaced = true
            return
        }
        guard follow else {
            panelMoving = false
            return
        }
        var toPanel = panel.position - eye
        toPanel.y = 0
        let angle = simd_length(toPanel) > 0.001 ? acos(min(max(simd_dot(simd_normalize(toPanel), forward), -1), 1)) : 0
        let distance = simd_distance(panel.position, target)
        if !panelMoving, angle > 35 * .pi / 180 || distance > 0.5 { panelMoving = true }
        guard panelMoving else { return }
        let t = 1 - exp(-deltaTime / 0.4)
        panel.position = simd_mix(panel.position, target, SIMD3<Float>(repeating: t))
        panel.orientation = simd_slerp(panel.orientation, facing, t)
        if distance < 0.02 { panelMoving = false }
    }

    func setMode(_ mode: PlacementMode) {
        self.mode = mode
        pivotMarker.isEnabled = mode == .precise
        refreshCollision()
    }

    func setPosition(_ position: SIMD3<Float>) {
        placement.position = position
        applyPlacement()
    }

    func setYaw(_ yaw: Float) {
        placement.yaw = Self.normalized(yaw)
        applyPlacement()
    }

    func setScale(_ scale: Float) {
        placement.scale = min(max(scale, 0.001), 1)
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
        placement.yaw = Self.normalized(yaw)
        applyPlacement()
        commitPlacement()
    }

    func commitPlacement() {
        guard let project else { return }
        placement.save(project: project)
        pinTask = Task { [previous = pinTask] in
            await previous?.value
            await pinWorldAnchor()
        }
    }

    private func applyPlacement() {
        root.position = placement.position
        root.orientation = simd_quatf(angle: placement.yaw, axis: [0, 1, 0])
        root.scale = SIMD3<Float>(repeating: placement.scale)
        handle.scale = SIMD3<Float>(repeating: 1 / placement.scale)
        pivotMarker.scale = SIMD3<Float>(repeating: 1 / placement.scale)
        applyMeasureScale()
    }

    private static func normalized(_ yaw: Float) -> Float {
        let wrapped = remainder(yaw, 2 * .pi)
        return wrapped <= -.pi ? wrapped + 2 * .pi : wrapped
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
                placement.yaw = Self.normalized(atan2(m.columns.2.x, m.columns.2.z))
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
