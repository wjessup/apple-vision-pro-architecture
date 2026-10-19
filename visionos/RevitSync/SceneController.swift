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
    var lockedCorners: [Int]?

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
        case .full: "1:1 Real size"
        case .twentieth: "1:20"
        case .fiftieth: "1:50"
        case .hundredth: "1:100"
        }
    }
}

enum PlacementMode: String, CaseIterable, Identifiable {
    case basic
    case precise
    case corners

    var id: String { rawValue }
    var label: String {
        switch self {
        case .basic: "Basic"
        case .precise: "Precise"
        case .corners: "Corners"
        }
    }
}

enum CornerState {
    case free
    case locked
    case unavailable
}

@MainActor
@Observable
final class SceneController {
    let root = Entity()
    let model = Entity()
    let handle: ModelEntity
    let pivotMarker: ModelEntity
    let cornerBalls: [ModelEntity]
    let scanMesh = ScanMesh()
    let measureRoot = Entity()

    private(set) var placement = Placement.tabletop
    private(set) var mode = PlacementMode.basic
    private(set) var corners: [SIMD3<Float>]?
    private var inputLocked = false
    private var pinTask: Task<Void, Never>?
    private(set) var project: String?
    private var scanAnchorID: UUID?
    private var partitions: [String: (sha256: String, entity: Entity, outline: [SIMD3<Float>], voids: [Footprint.Void])] = [:]
    var isGesturing = false
    var scaleLocked = true

    static let scaleRange: ClosedRange<Float> = 0.001...1

    private static let freeCornerMaterial = cornerMaterial(.systemOrange, opacity: 1)
    private static let lockedCornerMaterial = cornerMaterial(.systemGreen, opacity: 1)
    private static let unavailableCornerMaterial = cornerMaterial(.systemGray, opacity: 0.4)

    // At real size a footprint corner sits inside the walls and usually below the real floor
    // (footings), where the model and the scanned-room occluder would hide it, so corner balls
    // skip the depth test and draw in the transparent pass, after opaque geometry.
    private static func cornerMaterial(_ color: UIColor, opacity: Float) -> UnlitMaterial {
        var material = UnlitMaterial(color: color)
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        material.readsDepth = false
        return material
    }

    private(set) var measuring = false
    private(set) var preparingMeasure = false
    private(set) var measurements: [Measurement] = []
    private(set) var pendingPoint: SIMD3<Float>?
    var selectedMeasurement: UUID?
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

        cornerBalls = Footprint.cornerNames.map { name in
            let ball = ModelEntity(mesh: .generateSphere(radius: 0.04), materials: [SceneController.freeCornerMaterial])
            ball.name = "corner-\(name)"
            ball.generateCollisionShapes(recursive: false)
            ball.components.set(InputTargetComponent())
            let text = ModelEntity(
                mesh: .generateText(name, extrusionDepth: 0.002, font: .systemFont(ofSize: 0.05, weight: .bold)),
                materials: [SceneController.cornerMaterial(.white, opacity: 1)])
            text.position.x = -text.visualBounds(relativeTo: text).center.x
            let label = Entity()
            label.position = [0, 0.06, 0]
            label.components.set(BillboardComponent())
            label.addChild(text)
            ball.addChild(label)
            ball.isEnabled = false
            return ball
        }

        root.name = "root"
        root.components.set(InputTargetComponent())
        root.addChild(model)
        root.addChild(handle)
        root.addChild(pivotMarker)
        cornerBalls.forEach { root.addChild($0) }

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
        scanMesh.flushLive()
        self.project = project
        clear()
        placement = Placement.load(project: project) ?? .tabletop
        measurements = .load(project: project)
        setPending(nil)
        selectedMeasurement = nil
        redrawMeasurements()
        applyPlacement()
        refreshCornerBalls()
        let scan = ScanStore.load(project: project)
        scanAnchorID = scan.anchorID
        scanMesh.load(project: project, patches: scan.patches)
        Task { await ensureScanAnchor() }
    }

    func replace(partitionID: String, sha256: String, fileURL: URL) async throws {
        let entity = try await Entity(contentsOf: fileURL)
        entity.name = partitionID
        partitions[partitionID]?.entity.removeFromParent()
        meshShapes[partitionID] = nil
        model.addChild(entity)
        let voids = extractVoids(from: entity)
        partitions[partitionID] = (sha256, entity, outline(of: entity), voids)
        refreshCorners()
        refreshCollision()
        pushVoids()
    }

    func remove(partitionID: String) {
        partitions[partitionID]?.entity.removeFromParent()
        partitions[partitionID] = nil
        meshShapes[partitionID] = nil
        refreshCollision()
        refreshCorners()
        pushVoids()
    }

    func clear() {
        partitions.values.forEach { $0.entity.removeFromParent() }
        partitions.removeAll()
        meshShapes.removeAll()
        refreshCollision()
        refreshCorners()
        pushVoids()
    }

    var partitionCount: Int { partitions.count }

    /// Void prims (`void_*`) are invisible volumes exported only to cut the room scan; they leave the
    /// tree before the outline and colliders are built so they never widen the footprint or take taps.
    private func extractVoids(from entity: Entity) -> [Footprint.Void] {
        var found: [Entity] = []
        var stack = [entity]
        while let current = stack.popLast() {
            if current.name.hasPrefix("void_") {
                found.append(current)
            } else {
                stack.append(contentsOf: current.children)
            }
        }
        let voids = found.compactMap { void -> Footprint.Void? in
            var points: [SIMD3<Float>] = []
            var stack = [void]
            while let current = stack.popLast() {
                stack.append(contentsOf: current.children)
                points.append(contentsOf: modelPoints(of: current))
            }
            guard let top = points.map(\.y).max() else { return nil }
            return Footprint.Void(outline: Footprint.hull(points), top: top)
        }
        found.forEach { $0.removeFromParent() }
        return voids
    }

    private func pushVoids() {
        scanMesh.setVoids(partitions.values.flatMap(\.voids), worldFromModel: model.transformMatrix(relativeTo: nil))
    }

    private func outline(of entity: Entity) -> [SIMD3<Float>] {
        var outline: [SIMD3<Float>] = []
        var stack = [entity]
        while let current = stack.popLast() {
            stack.append(contentsOf: current.children)
            outline.append(contentsOf: Footprint.hull(modelPoints(of: current)))
        }
        return Footprint.hull(outline)
    }

    /// Model-space positions of one entity's own mesh (not its children's).
    private func modelPoints(of entity: Entity) -> [SIMD3<Float>] {
        guard let mesh = entity.components[ModelComponent.self]?.mesh else { return [] }
        let toModel = entity.transformMatrix(relativeTo: model)
        let contents = mesh.contents
        var points: [SIMD3<Float>] = []
        for instance in contents.instances {
            guard let meshModel = contents.models[instance.model] else { continue }
            let transform = toModel * instance.transform
            for part in meshModel.parts {
                points.append(contentsOf: part.positions.elements.map { p -> SIMD3<Float> in
                    let q = transform * SIMD4(p, 1)
                    return [q.x, q.y, q.z]
                })
            }
        }
        return points
    }

    private func refreshCorners() {
        corners = Footprint.corners(of: partitions.values.flatMap(\.outline))
        if let corners {
            zip(cornerBalls, corners).forEach { $0.position = $1 }
        }
        refreshCornerBalls()
    }

    private func refreshCollision() {
        Task { await refreshCollisionAsync() }
    }

    // Each partition mesh gets an exact collider (cached per partition load) rather than one
    // whole-model box: a real-size model's box encloses the user, and a gaze ray starting inside a
    // collider hits it at distance zero, stealing input from the tools panel and windows in front.
    // Each mesh also gets its own input target so a tap reports that mesh, not `root`.
    private var meshCollidersWanted: Bool { measuring || (mode == .basic && !inputLocked) }

    private func refreshCollisionAsync() async {
        handle.isEnabled = !inputLocked && !measuring && mode != .corners
        if meshCollidersWanted {
            for (id, partition) in partitions where meshShapes[id] == nil {
                meshShapes[id] = Task { await Self.staticShapes(for: partition.entity) }
            }
        }
        let tasks = meshShapes
        preparingMeasure = measuring
        var ready: [[(entity: Entity, shape: ShapeResource)]] = []
        for task in tasks.values { ready.append(await task.value) }
        preparingMeasure = false
        for shapes in ready {
            for (entity, shape) in shapes {
                if meshCollidersWanted, entity.parent != nil {
                    entity.components.set(CollisionComponent(shapes: [shape], isStatic: true))
                    entity.components.set(InputTargetComponent())
                } else {
                    entity.components.remove(CollisionComponent.self)
                    entity.components.remove(InputTargetComponent.self)
                }
            }
        }
    }

    // MARK: Placement

    func setLocked(_ locked: Bool) {
        inputLocked = locked
        cornerBalls.forEach { $0.components[InputTargetComponent.self]?.isEnabled = !locked }
        refreshCollision()
    }

    // MARK: Measurements

    var atRealSize: Bool { abs(placement.scale - ScalePreset.full.rawValue) < 0.0001 }

    func setMeasuring(_ measuring: Bool) {
        self.measuring = measuring && atRealSize
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
        if mode != .corners, placement.lockedCorners != nil {
            placement.lockedCorners = nil
            commitPlacement()
        }
        refreshCollision()
        refreshCornerBalls()
    }

    // MARK: Corners

    var lockedCorners: [Int] { placement.lockedCorners ?? [] }

    func cornerState(_ index: Int) -> CornerState {
        let locked = lockedCorners
        if locked.contains(index) { return .locked }
        return locked.count >= 2 ? .unavailable : .free
    }

    func cornerIndex(of entity: Entity) -> Int? {
        cornerBalls.firstIndex { $0 === entity }
    }

    func cornerWorld(_ index: Int) -> SIMD3<Float>? {
        guard let corners else { return nil }
        return Footprint.world(corners[index], position: placement.position, yaw: placement.yaw, scale: placement.scale)
    }

    func toggleCornerLock(_ index: Int) {
        guard corners != nil else { return }
        var locked = lockedCorners
        if let existing = locked.firstIndex(of: index) {
            locked.remove(at: existing)
        } else if locked.count < 2 {
            locked.append(index)
        } else {
            return
        }
        placement.lockedCorners = locked.isEmpty ? nil : locked
        refreshCornerBalls()
        commitPlacement()
    }

    func dragCorner(_ index: Int, to target: SIMD3<Float>) {
        guard let corners, cornerState(index) == .free, let current = cornerWorld(index) else { return }
        if let anchor = lockedCorners.first, let anchorWorld = cornerWorld(anchor) {
            let range = scaleLocked ? placement.scale...placement.scale : Self.scaleRange
            guard let solved = Footprint.solveTwoPoint(
                a: corners[anchor], aWorld: anchorWorld, b: corners[index], target: target, scaleRange: range)
            else { return }
            placement.position = solved.position
            placement.yaw = Self.normalized(solved.yaw)
            placement.scale = solved.scale
        } else {
            placement.position += target - current
        }
        applyPlacement()
    }

    private func refreshCornerBalls() {
        let visible = mode == .corners && corners != nil
        for (index, ball) in cornerBalls.enumerated() {
            ball.isEnabled = visible
            let material: any Material = switch cornerState(index) {
            case .free: Self.freeCornerMaterial
            case .locked: Self.lockedCornerMaterial
            case .unavailable: Self.unavailableCornerMaterial
            }
            ball.model?.materials = [material]
        }
    }

    // Balls keep their 8 cm size within 1.5 m of the user and grow linearly beyond it, so they
    // cover a constant visual angle when the corners of a real-size model are far away.
    func updateCornerBallSize() {
        let eye = devicePose().map { SIMD3<Float>($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
        for ball in cornerBalls where ball.isEnabled || eye == nil {
            let distance = eye.map { simd_distance(ball.position(relativeTo: nil), $0) } ?? 0
            ball.scale = SIMD3<Float>(repeating: max(1, distance / 1.5) / placement.scale)
        }
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
        placement.scale = min(max(scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
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
        pushVoids()
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
        updateCornerBallSize()
        // Measurements are only taken and shown at real size.
        measureRoot.isEnabled = atRealSize
        if !atRealSize {
            if selectedMeasurement != nil { selectedMeasurement = nil }
            if measuring { setMeasuring(false) }
        }
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
            Task {
                // Providers pause while the immersive space is closed; a project picked or cleared
                // in that state gets its scan anchor when tracking resumes.
                for await event in session.events {
                    if case .dataProviderStateChanged(_, .running, _) = event {
                        await ensureScanAnchor()
                    }
                }
            }
            Task { await ensureScanAnchor() }
            for await update in worldTracking.anchorUpdates {
                if case .removed = update.event { continue }
                guard update.anchor.isTracked else { continue }
                let m = update.anchor.originFromAnchorTransform
                if update.anchor.id == scanAnchorID {
                    scanMesh.setAnchorTransform(m)
                }
                guard update.anchor.id == placement.anchorID, !isGesturing else { continue }
                placement.position = [m.columns.3.x, m.columns.3.y, m.columns.3.z]
                placement.yaw = Self.normalized(atan2(m.columns.2.x, m.columns.2.z))
                applyPlacement()
                pushVoids()
            }
        }
    }

    // MARK: Scan

    /// Pins the project's scan anchor at the session origin the first time the project is scanned.
    /// Remembered patches are stored relative to it, so visionOS re-locating the anchor in a later
    /// session puts them back where they were.
    private func ensureScanAnchor() async {
        guard worldTracking.state == .running, let project else { return }
        if let scanAnchorID {
            // Switching back to a project whose anchor is already tracked produces no new update.
            let known = await worldTracking.allAnchors?.first { $0.id == scanAnchorID }
            guard self.project == project, self.scanAnchorID == scanAnchorID, let known, known.isTracked else { return }
            scanMesh.setAnchorTransform(known.originFromAnchorTransform)
            return
        }
        let anchor = WorldAnchor(originFromAnchorTransform: matrix_identity_float4x4)
        guard (try? await worldTracking.addAnchor(anchor)) != nil else { return }
        guard self.project == project, scanAnchorID == nil else {
            try? await worldTracking.removeAnchor(forID: anchor.id)
            return
        }
        scanAnchorID = anchor.id
        ScanStore.saveAnchor(anchor.id, project: project)
        scanMesh.setAnchorTransform(anchor.originFromAnchorTransform)
    }

    func clearScan() {
        guard let project else { return }
        ScanStore.clear(project: project)
        scanMesh.clear()
        let old = scanAnchorID
        scanAnchorID = nil
        Task {
            if let old { try? await worldTracking.removeAnchor(forID: old) }
            await ensureScanAnchor()
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
