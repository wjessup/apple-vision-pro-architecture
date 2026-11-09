import ARKit
import Foundation
import QuartzCore
import RealityKit
import simd
import UIKit

struct Placement: Codable, Equatable {
    var position: SIMD3<Float>
    var yaw: Float
    var scale: Float
    var anchorID: UUID?
    var lockedCorners: [Int]?
    /// Ground-floor corners (model space) of the model this placement was set with.
    var footprint: [SIMD3<Float>]?
    /// Where the model sits in the room scan's frame (column-major 4×4, like
    /// `ScanAnchorRecord.scanFromAnchor`), so any recognised scan pin can restore the house when its
    /// own world anchor is not found. Nil until placed while the scan is aligned, and after Clear scan.
    var scanFromModel: [Float]?

    static let tabletop = Placement(position: [0, 0.8, -1.0], yaw: 0, scale: ScalePreset.fiftieth.rawValue)
}

/// Whether the saved placement has been located in this session. Saved numbers are in the
/// previous session's coordinates, so the model stays hidden until a world anchor locates it.
enum PlacementStatus: Equatable {
    /// Nothing saved to look for (first use), or placed by hand this session.
    case placed
    case searching(since: Date)
    case found(via: PlacementSource, after: TimeInterval)
}

enum PlacementSource {
    /// The model's own world anchor.
    case anchor
    /// The room scan's pins, through `Placement.scanFromModel`.
    case scan
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

/// Both walkable ends of one staircase, in model space.
struct Stair: Identifiable, Equatable {
    let id: String
    let bottom: SIMD3<Float>
    let top: SIMD3<Float>
}

enum CornerState {
    case free
    case locked
    case unavailable
}

enum Tool {
    case none
    case measure
    case voidSurface
    case voidPolygon
}

enum Selection: Equatable {
    case measurement(UUID)
    case void(UUID)
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
    let marksRoot = Entity()
    let stairRoot = Entity()
    let panelRoot = Entity()
    let panelGrip: ModelEntity

    private(set) var placement = Placement.tabletop
    private(set) var placementStatus = PlacementStatus.placed {
        didSet { root.isEnabled = !isSearching }
    }
    /// Shown on the tools panel while searching and for a few seconds after the placement is found.
    private(set) var placementNotice: String?
    private var noticeTask: Task<Void, Never>?
    private var searchStart: Date?
    private var houseAnchorTracked = false
    /// Posts at every world anchor (model and scan pins); shown with *Show anchors*. Outside `root`,
    /// so they stay visible while the model is hidden and are never scaled with it.
    let anchorMarkers = Entity()
    private let housePin: Entity
    private var pinMarkers: [UUID: (entity: Entity, tracked: Bool, label: Int)] = [:]
    private(set) var mode = PlacementMode.basic
    private(set) var corners: [SIMD3<Float>]?
    /// The loaded model's ground-floor corners are more than a foot from the placed house's.
    private(set) var footprintMismatch = false
    private var inputLocked = false
    private var pinTask: Task<Void, Never>?
    private(set) var project: String?
    private var creatingScanAnchor = false
    private var scanAnchorAddFailed = false
    private var scanEpoch = 0
    private var partitions: [String: (sha256: String, entity: Entity, outline: [SIMD3<Float>], voids: [Footprint.Void], stairs: [Stair])] = [:]
    private(set) var stairs: [Stair] = []
    /// Model height (metres) of the floor put on the real floor; session-only, never saved.
    private(set) var floorElevation: Float = 0
    private var stairAnchors: [String: Entity] = [:]
    var isGesturing = false
    var scaleLocked = true

    static let scaleRange: ClosedRange<Float> = 0.001...1

    private static let freeCornerMaterial = cornerMaterial(.systemOrange, opacity: 1)
    private static let lockedCornerMaterial = cornerMaterial(.systemGreen, opacity: 1)
    private static let unavailableCornerMaterial = cornerMaterial(.systemGray, opacity: 0.4)

    // At real size a footprint corner sits inside the walls at floor level, where the model and the
    // scanned-room occluder would hide it, so corner balls
    // skip the depth test and draw in the transparent pass, after opaque geometry.
    private static func cornerMaterial(_ color: UIColor, opacity: Float) -> UnlitMaterial {
        var material = UnlitMaterial(color: color)
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        material.readsDepth = false
        return material
    }

    private static func lockIcon() -> Entity {
        let material = cornerMaterial(.white, opacity: 1)
        let icon = Entity()
        icon.name = "lock"
        icon.position = [0, 0.065, 0]
        icon.components.set(BillboardComponent())
        let parts: [(size: SIMD3<Float>, at: SIMD3<Float>)] = [
            ([0.04, 0.032, 0.012], [0, 0, 0]),
            ([0.006, 0.02, 0.006], [-0.013, 0.026, 0]),
            ([0.006, 0.02, 0.006], [0.013, 0.026, 0]),
            ([0.032, 0.006, 0.006], [0, 0.036, 0]),
        ]
        for part in parts {
            let box = ModelEntity(mesh: .generateBox(size: part.size), materials: [material])
            box.position = part.at
            icon.addChild(box)
        }
        icon.isEnabled = false
        return icon
    }

    private(set) var tool = Tool.none
    var toolActive: Bool { tool != .none }
    private(set) var measurements: [Measurement] = []
    private(set) var pendingPoint: SIMD3<Float>?
    private(set) var voidMarks: [VoidMark] = []
    private(set) var pendingPolygon: [SIMD3<Float>] = []
    var selection: Selection? {
        didSet { applyHighlight() }
    }
    private var meshShapes: [String: Task<[(entity: Entity, shape: ShapeResource)], Never>] = [:]
    private var measureEntities: [UUID: Entity] = [:]
    private var voidEntities: [UUID: Entity] = [:]
    private let pendingDot: ModelEntity
    private let pendingLayer = Entity()
    private static let measureMaterial = UnlitMaterial(color: .systemYellow)
    private static let voidMaterial = UnlitMaterial(color: .systemBlue)
    private static let selectedMaterial = UnlitMaterial(color: .white)
    private var panelPlaced = false
    private var panelMoving = false
    private static let defaultPanelOffset: SIMD3<Float> = [0, -0.3, -0.6]
    private var panelOffset = SceneController.defaultPanelOffset

    var loadedPartitions: [String: String] { partitions.mapValues(\.sha256) }

    private let session = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private let sceneReconstruction = SceneReconstructionProvider()
    private var trackingTask: Task<Void, Never>?

    init(legacyProject: String?) {
        Self.adoptLegacySite(keeping: legacyProject)
        placement = Placement.load() ?? .tabletop
        if placement.anchorID != nil || placement.scanFromModel != nil {
            placementStatus = .searching(since: Date())
            placementNotice = Self.searchingNotice
        }
        housePin = Self.post(height: 1.2, arrow: true)
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

        var gripMaterial = UnlitMaterial(color: .white)
        gripMaterial.blending = .transparent(opacity: 0.8)
        panelGrip = ModelEntity(mesh: .generateBox(size: [0.12, 0.012, 0.012], cornerRadius: 0.006), materials: [gripMaterial])
        panelGrip.name = "panelGrip"
        panelGrip.position = [0, -0.045, 0]
        panelGrip.components.set(CollisionComponent(shapes: [.generateBox(size: [0.14, 0.03, 0.03])]))
        panelGrip.components.set(InputTargetComponent())
        panelGrip.components.set(HoverEffectComponent())
        panelRoot.name = "toolsPanel"
        panelRoot.addChild(panelGrip)

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
            label.position = [0, 0.13, 0]
            label.components.set(BillboardComponent())
            label.addChild(text)
            ball.addChild(label)
            ball.addChild(SceneController.lockIcon())
            ball.isEnabled = false
            return ball
        }

        root.name = "root"
        root.isEnabled = !isSearching
        anchorMarkers.name = "anchorMarkers"
        anchorMarkers.isEnabled = false
        housePin.isEnabled = false
        anchorMarkers.addChild(housePin)
        root.components.set(InputTargetComponent())
        root.addChild(model)
        root.addChild(handle)
        root.addChild(pivotMarker)
        cornerBalls.forEach { root.addChild($0) }

        pendingDot.isEnabled = false
        marksRoot.name = "marks"
        marksRoot.addChild(pendingDot)
        marksRoot.addChild(pendingLayer)
        root.addChild(marksRoot)
        stairRoot.name = "stairs"
        root.addChild(stairRoot)
        refreshCollision()
        applyPlacement()
        let scan = ScanStore.load()
        scanMesh.load(anchors: scan.anchors, cells: scan.cells)
    }

    /// Placement and scan used to be kept per model. On first launch after they became site-wide,
    /// the selected model's are kept and every other model's world anchors are released.
    private static func adoptLegacySite(keeping project: String?) {
        let defaults = UserDefaults.standard
        guard defaults.data(forKey: Placement.key) == nil,
              !FileManager.default.fileExists(atPath: ScanStore.directory.path) else { return }
        if let project, let data = defaults.data(forKey: "\(Placement.key).\(project)") {
            defaults.set(data, forKey: Placement.key)
        }
        var stale: [UUID] = []
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("\(Placement.key).") {
            if key != "\(Placement.key).\(project ?? "")", let data = value as? Data,
               let id = (try? JSONDecoder().decode(Placement.self, from: data))?.anchorID {
                stale.append(id)
            }
            defaults.removeObject(forKey: key)
        }
        ScanStore.addStaleAnchors(stale)
        ScanStore.adoptLegacyScans(keeping: project)
    }

    // MARK: Partitions

    func activate(project: String) {
        guard self.project != project else { return }
        self.project = project
        clear()
        measurements = .load(project: project)
        voidMarks = .load(project: project)
        setPending(nil)
        pendingPolygon = []
        redrawPendingPolygon()
        selection = nil
        redrawMeasurements()
        redrawVoids()
        floorElevation = 0
        applyPlacement()
    }

    func replace(partitionID: String, sha256: String, fileURL: URL) async throws {
        let entity = try await Entity(contentsOf: fileURL)
        entity.name = partitionID
        partitions[partitionID]?.entity.removeFromParent()
        meshShapes[partitionID] = nil
        model.addChild(entity)
        let voids = extractVoids(from: entity)
        let stairs = extractStairs(from: entity)
        partitions[partitionID] = (sha256, entity, outline(of: entity), voids, stairs)
        refreshStairs()
        refreshCorners()
        refreshCollision()
        pushVoids()
    }

    func remove(partitionID: String) {
        partitions[partitionID]?.entity.removeFromParent()
        partitions[partitionID] = nil
        meshShapes[partitionID] = nil
        refreshStairs()
        refreshCollision()
        refreshCorners()
        pushVoids()
    }

    func clear() {
        partitions.values.forEach { $0.entity.removeFromParent() }
        partitions.removeAll()
        meshShapes.removeAll()
        refreshStairs()
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

    /// Stair markers (`stair_e<id>_bottom` / `_top`) are empty Xforms; they are paired by element
    /// and taken out of the tree like voids.
    private func extractStairs(from entity: Entity) -> [Stair] {
        var ends: [String: (bottom: SIMD3<Float>?, top: SIMD3<Float>?)] = [:]
        var found: [Entity] = []
        var stack = [entity]
        while let current = stack.popLast() {
            stack.append(contentsOf: current.children)
            let name = current.name
            guard name.hasPrefix("stair_e") else { continue }
            let position = current.position(relativeTo: model)
            if name.hasSuffix("_bottom") {
                ends[String(name.dropLast("_bottom".count)), default: (nil, nil)].bottom = position
            } else if name.hasSuffix("_top") {
                ends[String(name.dropLast("_top".count)), default: (nil, nil)].top = position
            } else {
                continue
            }
            found.append(current)
        }
        found.forEach { $0.removeFromParent() }
        return ends.compactMap { id, end in
            guard let bottom = end.bottom, let top = end.top else { return nil }
            return Stair(id: id, bottom: bottom, top: top)
        }.sorted { $0.id < $1.id }
    }

    /// One anchor per stair end, a metre above it, carrying its Go up / Go down button.
    private func refreshStairs() {
        stairs = partitions.values.flatMap(\.stairs).sorted { $0.id < $1.id }
        stairAnchors.values.forEach { $0.removeFromParent() }
        stairAnchors.removeAll()
        for stair in stairs {
            for (key, at) in [(Self.stairButtonID(stair, up: true), stair.bottom), (Self.stairButtonID(stair, up: false), stair.top)] {
                let anchor = Entity()
                anchor.position = at + [0, 1, 0]
                stairRoot.addChild(anchor)
                stairAnchors[key] = anchor
            }
        }
    }

    static func stairButtonID(_ stair: Stair, up: Bool) -> String { "\(stair.id)-\(up ? "up" : "down")" }

    func stairAnchor(id: String) -> Entity? { stairAnchors[id] }

    func goToFloor(_ elevation: Float) {
        floorElevation = elevation
        applyPlacement()
        pushVoids()
    }

    private func pushVoids() {
        scanMesh.setVoids(partitions.values.flatMap(\.voids) + voidMarks.map(\.void), worldFromModel: model.transformMatrix(relativeTo: nil))
    }

    private func outline(of entity: Entity) -> [SIMD3<Float>] {
        var outline: [SIMD3<Float>] = []
        var stack = [entity]
        while let current = stack.popLast() {
            stack.append(contentsOf: current.children)
            outline.append(contentsOf: Footprint.hull(groundSection(of: current)))
        }
        return Footprint.hull(outline)
    }

    private func groundSection(of entity: Entity) -> [SIMD3<Float>] {
        guard let mesh = entity.components[ModelComponent.self]?.mesh else { return [] }
        let toModel = entity.transformMatrix(relativeTo: model)
        let contents = mesh.contents
        var points: [SIMD3<Float>] = []
        for instance in contents.instances {
            guard let meshModel = contents.models[instance.model] else { continue }
            let transform = toModel * instance.transform
            for part in meshModel.parts {
                guard let indices = part.triangleIndices?.elements else { continue }
                let positions = part.positions.elements.map { p -> SIMD3<Float> in
                    let q = transform * SIMD4(p, 1)
                    return [q.x, q.y, q.z]
                }
                points.append(contentsOf: Footprint.groundSection(positions: positions, indices: indices))
            }
        }
        return points
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
            if let house = placement.footprint {
                footprintMismatch = !Footprint.sameHouse(corners, house)
            } else {
                placement.footprint = corners
                placement.save()
            }
        } else {
            footprintMismatch = false
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
    // Shapes are generated as soon as a partition loads, not when a tool first needs them, so
    // turning the ruler on is instant instead of waiting on the whole model.
    private var meshCollidersWanted: Bool { toolActive || (mode == .basic && !inputLocked) }

    private func refreshCollisionAsync() async {
        handle.isEnabled = !inputLocked && !toolActive && mode != .corners
        for (id, partition) in partitions where meshShapes[id] == nil {
            meshShapes[id] = Task { await Self.staticShapes(for: partition.entity) }
        }
        let tasks = meshShapes
        var ready: [[(entity: Entity, shape: ShapeResource)]] = []
        for task in tasks.values { ready.append(await task.value) }
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

    // MARK: Tools

    var atRealSize: Bool { abs(placement.scale - ScalePreset.full.rawValue) < 0.0001 }

    func setTool(_ tool: Tool) {
        self.tool = atRealSize ? tool : .none
        setPending(nil)
        pendingPolygon = []
        redrawPendingPolygon()
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
        if selection == .measurement(id) { selection = nil }
        saveMeasurements()
    }

    /// The element's whole plan outline becomes the void, the same shape `extractVoids` builds for an
    /// element marked as a void in Revit: every mesh named `e<elementId>_<n>` shares the hit mesh's prefix.
    func addVoid(fromElement entity: Entity) {
        guard entity.name.hasPrefix("e"), let underscore = entity.name.lastIndex(of: "_") else { return }
        let prefix = String(entity.name[...underscore])
        let points = Self.meshEntities(in: model).filter { $0.name.hasPrefix(prefix) }.flatMap(modelPoints(of:))
        guard let top = points.map(\.y).max() else { return }
        let outline = Footprint.hull(points)
        guard outline.count >= 3 else { return }
        voidMarks.append(VoidMark(outline: outline, top: top))
        saveVoidMarks()
    }

    func addPolygonPoint(_ point: SIMD3<Float>) {
        pendingPolygon.append(point)
        redrawPendingPolygon()
    }

    func finishPolygon() {
        guard pendingPolygon.count >= 3, let top = pendingPolygon.map(\.y).max() else { return }
        voidMarks.append(VoidMark(outline: pendingPolygon, top: top))
        pendingPolygon = []
        redrawPendingPolygon()
        saveVoidMarks()
    }

    func deleteSelected() {
        switch selection {
        case .measurement(let id):
            deleteMeasurement(id: id)
        case .void(let id):
            voidMarks.removeAll { $0.id == id }
            selection = nil
            saveVoidMarks()
        case nil:
            return
        }
    }

    /// The mark whose layer the entity belongs to; a measurement label's attachment is left to its own buttons.
    func selection(of entity: Entity) -> Selection? {
        var current: Entity? = entity
        while let e = current, e.parent !== marksRoot {
            if e.name == "label" { return nil }
            current = e.parent
        }
        guard let layer = current else { return nil }
        if let id = measureEntities.first(where: { $0.value === layer })?.key { return .measurement(id) }
        if let id = voidEntities.first(where: { $0.value === layer })?.key { return .void(id) }
        return nil
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

    private func saveVoidMarks() {
        if let project { voidMarks.save(project: project) }
        redrawVoids()
        pushVoids()
    }

    // Lines carry a 4 cm box collider (the box scales with the line's length) and an input target, so
    // gaze highlights them and a pinch selects the mark they belong to.
    private static func lineEntity(radius: Float, material: UnlitMaterial) -> ModelEntity {
        let line = ModelEntity(mesh: .generateCylinder(height: 1, radius: radius), materials: [material])
        line.components.set(CollisionComponent(shapes: [.generateBox(size: [0.04, 1, 0.04])]))
        line.components.set(InputTargetComponent())
        line.components.set(HoverEffectComponent())
        return line
    }

    private static func layout(_ line: Entity, from a: SIMD3<Float>, to b: SIMD3<Float>, scale s: Float) {
        let delta = b - a
        let length = simd_length(delta)
        line.position = (a + b) / 2 * s
        line.scale = [1, max(length * s, 0.0001), 1]
        if length > 0 { line.orientation = simd_quatf(from: [0, 1, 0], to: delta / length) }
    }

    private func redrawMeasurements() {
        measureEntities.values.forEach { $0.removeFromParent() }
        measureEntities.removeAll()
        for measurement in measurements {
            let layer = Entity()
            layer.addChild(Self.lineEntity(radius: 0.003, material: Self.measureMaterial))
            for _ in 0..<2 {
                layer.addChild(ModelEntity(mesh: .generateSphere(radius: 0.008), materials: [Self.measureMaterial]))
            }
            let label = Entity()
            label.name = "label"
            layer.addChild(label)
            marksRoot.addChild(layer)
            measureEntities[measurement.id] = layer
        }
        applyMarkScale()
        applyHighlight()
    }

    private func redrawVoids() {
        voidEntities.values.forEach { $0.removeFromParent() }
        voidEntities.removeAll()
        for mark in voidMarks {
            let layer = Entity()
            for _ in mark.outline {
                layer.addChild(Self.lineEntity(radius: 0.004, material: Self.voidMaterial))
            }
            marksRoot.addChild(layer)
            voidEntities[mark.id] = layer
        }
        applyMarkScale()
        applyHighlight()
    }

    private func redrawPendingPolygon() {
        pendingLayer.children.forEach { $0.removeFromParent() }
        for _ in pendingPolygon {
            pendingLayer.addChild(ModelEntity(mesh: .generateSphere(radius: 0.01), materials: [Self.voidMaterial]))
        }
        for _ in pendingPolygon.dropLast() {
            pendingLayer.addChild(ModelEntity(mesh: .generateCylinder(height: 1, radius: 0.004), materials: [Self.voidMaterial]))
        }
        applyMarkScale()
    }

    // Each mark layer is counter-scaled so dots, lines and labels keep a constant real size;
    // positions inside it are therefore model coordinates multiplied by the model scale.
    private func applyMarkScale() {
        let s = placement.scale
        let counter = SIMD3<Float>(repeating: 1 / s)
        pendingDot.scale = counter
        for measurement in measurements {
            guard let layer = measureEntities[measurement.id] else { continue }
            layer.scale = counter
            let children = Array(layer.children)
            Self.layout(children[0], from: measurement.a, to: measurement.b, scale: s)
            children[1].position = measurement.a * s
            children[2].position = measurement.b * s
            children[3].position = (measurement.a + measurement.b) / 2 * s + [0, 0.04, 0]
        }
        for mark in voidMarks {
            guard let layer = voidEntities[mark.id] else { continue }
            layer.scale = counter
            let edges = Array(layer.children)
            for (i, a) in mark.outline.enumerated() {
                Self.layout(edges[i], from: a, to: mark.outline[(i + 1) % mark.outline.count], scale: s)
            }
        }
        pendingLayer.scale = counter
        let pending = Array(pendingLayer.children)
        for (i, point) in pendingPolygon.enumerated() {
            pending[i].position = point * s
        }
        for i in pendingPolygon.indices.dropLast() {
            Self.layout(pending[pendingPolygon.count + i], from: pendingPolygon[i], to: pendingPolygon[i + 1], scale: s)
        }
    }

    private func applyHighlight() {
        for (id, layer) in measureEntities {
            Self.paint(layer, selection == .measurement(id) ? Self.selectedMaterial : Self.measureMaterial)
        }
        for (id, layer) in voidEntities {
            Self.paint(layer, selection == .void(id) ? Self.selectedMaterial : Self.voidMaterial)
        }
    }

    private static func paint(_ layer: Entity, _ material: UnlitMaterial) {
        for case let part as ModelEntity in layer.children {
            part.model?.materials = [material]
        }
    }

    // Labels keep their size within 1.5 m of the user and grow linearly beyond it, like corner
    // balls, so a distance reads from across a site.
    func updateMarkSizes() {
        guard let pose = devicePose() else { return }
        let eye = Self.translation(pose)
        for layer in measureEntities.values {
            guard let label = layer.findEntity(named: "label") else { continue }
            label.scale = SIMD3<Float>(repeating: max(1, simd_distance(label.position(relativeTo: nil), eye) / 1.5))
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

    // The panel sits at `panelOffset` in the wearer's yaw frame (default: 0.6 m ahead, 0.3 m below
    // the eyes); dragging the grab bar rewrites the offset for the session. Lazy follow: the panel
    // stays put while it is roughly where the wearer left it and only eases back once it has
    // drifted out of view or reach, avoiding head-locked UI.
    func resetPanel() {
        panelPlaced = false
        panelMoving = false
        panelOffset = Self.defaultPanelOffset
    }

    func updatePanel(deltaTime: Float, follow: Bool) {
        guard let pose = devicePose() else {
            if !panelPlaced { panelRoot.position = [0, 1.1, -0.6] }
            return
        }
        let eye = Self.translation(pose)
        let target = eye + Self.yawRotation(pose).act(panelOffset)
        let facing = Self.facing(from: eye, to: target)

        guard panelPlaced else {
            panelRoot.position = target
            panelRoot.orientation = facing
            panelPlaced = true
            return
        }
        guard follow else {
            panelMoving = false
            return
        }
        var toPanel = panelRoot.position - eye
        var toTarget = target - eye
        toPanel.y = 0
        toTarget.y = 0
        let angle = simd_length(toPanel) > 0.001 && simd_length(toTarget) > 0.001
            ? acos(min(max(simd_dot(simd_normalize(toPanel), simd_normalize(toTarget)), -1), 1)) : 0
        let distance = simd_distance(panelRoot.position, target)
        if !panelMoving, angle > 35 * .pi / 180 || distance > 0.5 { panelMoving = true }
        guard panelMoving else { return }
        let t = 1 - exp(-deltaTime / 0.4)
        panelRoot.position = simd_mix(panelRoot.position, target, SIMD3<Float>(repeating: t))
        panelRoot.orientation = simd_slerp(panelRoot.orientation, facing, t)
        if distance < 0.02 { panelMoving = false }
    }

    func dragPanel(to position: SIMD3<Float>) {
        panelRoot.position = position
        panelMoving = false
        guard let pose = devicePose() else { return }
        let eye = Self.translation(pose)
        panelOffset = Self.yawRotation(pose).inverse.act(position - eye)
        panelRoot.orientation = Self.facing(from: eye, to: position)
    }

    /// Rotation about Y taking the wearer's frame (−Z ahead) to their heading.
    private static func yawRotation(_ pose: simd_float4x4) -> simd_quatf {
        var forward = -SIMD3<Float>(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
        forward.y = 0
        forward = simd_length(forward) > 0.001 ? simd_normalize(forward) : [0, 0, -1]
        return simd_quatf(angle: atan2(forward.x, forward.z) + .pi, axis: [0, 1, 0])
    }

    /// Orientation of an attachment at `position` that faces the wearer at `eye`.
    private static func facing(from eye: SIMD3<Float>, to position: SIMD3<Float>) -> simd_quatf {
        var direction = position - eye
        direction.y = 0
        direction = simd_length(direction) > 0.001 ? simd_normalize(direction) : [0, 0, -1]
        return simd_quatf(angle: atan2(direction.x, direction.z) + .pi, axis: [0, 1, 0])
    }

    func setMode(_ mode: PlacementMode) {
        self.mode = mode
        // Corner balls are aligned against real-world spots on the ground.
        if mode == .corners, floorElevation != 0 { goToFloor(0) }
        pivotMarker.isEnabled = mode == .precise
        refreshCollision()
        refreshCornerBalls()
    }

    // MARK: Corners

    var lockedCorners: [Int] { placement.lockedCorners ?? [] }

    /// A locked corner pins the model; only vertical moves and swinging a free corner around it are allowed.
    var cornerLocked: Bool { !lockedCorners.isEmpty }
    private(set) var lockWarning: String?
    private var warningTask: Task<Void, Never>?

    func warnCornerLocked() {
        lockWarning = "A corner is locked. Tap its lock to unlock it before moving the model."
        warningTask?.cancel()
        warningTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { lockWarning = nil }
        }
    }

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
            ball.findEntity(named: "lock")?.isEnabled = cornerState(index) == .locked
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
        if atRealSize, let pending = pendingSharedPlacement { adoptSharedPlacement(scanFromModel: pending) }
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
        // While searching this starts over: the saved anchor and locked corners are given up.
        if isSearching {
            placement.lockedCorners = nil
            refreshCornerBalls()
            setStatus(.placed)
        }
        placement.position = position
        placement.yaw = Self.normalized(yaw)
        applyPlacement()
        commitPlacement()
    }

    var isSearching: Bool {
        if case .searching = placementStatus { return true }
        return false
    }

    private static let searchingNotice = "Finding your placement… look around where you placed the house"

    private func setStatus(_ status: PlacementStatus) {
        placementStatus = status
        noticeTask?.cancel()
        switch status {
        case .placed:
            placementNotice = nil
        case .searching:
            placementNotice = Self.searchingNotice
        case .found(let via, let after):
            placementNotice = via == .scan
                ? "Placement restored from the room scan"
                : "Placement found after \(Int(after.rounded())) s"
            noticeTask = Task {
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled { placementNotice = nil }
            }
        }
    }

    /// Ends a search, or upgrades a placement restored from the scan once the model's own, more
    /// precise anchor is found.
    private func found(via source: PlacementSource) {
        switch placementStatus {
        case .searching(let since):
            searchStart = since
        case .found(.scan, _) where source == .anchor:
            break
        default:
            return
        }
        setStatus(.found(via: source, after: Date().timeIntervalSince(searchStart ?? Date())))
    }

    /// The model's own world anchor locates it: adopt its pose. While searching this ends the
    /// search, and records the model in the scan frame if it never was, so the scan can restore it
    /// next time.
    private func adoptAnchorPose(_ m: simd_float4x4) {
        placement.position = Self.translation(m)
        placement.yaw = Self.normalized(atan2(m.columns.2.x, m.columns.2.z))
        applyPlacement()
        pushVoids()
        found(via: .anchor)
        recordScanFrame()
    }

    /// With the model's anchor not found yet, any recognised scan pin can place it through
    /// `scanFromModel`; once located, a model never placed in the scan frame gets recorded in it.
    private func syncScanFrame() {
        guard scanMesh.isAligned else { return }
        if isSearching {
            guard let scanFromModel = placement.scanFromModel.map(ScanMesh.matrix),
                  let originFromScan = scanMesh.originFromScan(nearScan: Self.translation(scanFromModel)) else { return }
            let m = originFromScan * scanFromModel
            placement.position = Self.translation(m)
            placement.yaw = Self.normalized(atan2(m.columns.2.x, m.columns.2.z))
            applyPlacement()
            pushVoids()
            found(via: .scan)
        } else if atRealSize, let pending = pendingSharedPlacement {
            adoptSharedPlacement(scanFromModel: pending)
        } else {
            recordScanFrame()
        }
    }

    private func recordScanFrame() {
        guard placement.scanFromModel == nil, !isSearching,
              let originFromScan = scanMesh.originFromScan(near: placement.position) else { return }
        let scanFromModel = originFromScan.inverse * placementTransform
        placement.scanFromModel = ScanMesh.columns(scanFromModel)
        placement.save()
        if atRealSize { onPlacementPublished?(scanFromModel) }
    }

    /// The model's pose without scale: what its world anchor and `scanFromModel` record.
    private var placementTransform: simd_float4x4 {
        var transform = simd_float4x4(simd_quatf(angle: placement.yaw, axis: [0, 1, 0]))
        transform.columns.3 = SIMD4(placement.position, 1)
        return transform
    }

    /// Saves the placement and re-pins its world anchor. Refused while searching: the saved anchor
    /// is the only record of where the house really is, and a commit now would replace it with one
    /// at the wrong spot.
    func commitPlacement() {
        guard !isSearching else { return }
        // The model placed last is the house every other model is checked against.
        if let corners {
            placement.footprint = corners
            footprintMismatch = false
        }
        placement.scanFromModel = scanMesh.originFromScan(near: placement.position).map { ScanMesh.columns($0.inverse * placementTransform) }
        placement.save()
        pushVoids()
        repin()
        if atRealSize, let scanFromModel = placement.scanFromModel {
            pendingSharedPlacement = nil
            onPlacementPublished?(ScanMesh.matrix(scanFromModel))
        }
    }

    private func repin() {
        pinTask = Task { [previous = pinTask] in
            await previous?.value
            await pinWorldAnchor()
        }
    }

    private func applyPlacement() {
        if !atRealSize { floorElevation = 0 }
        root.position = placement.position - [0, floorElevation * placement.scale, 0]
        root.orientation = simd_quatf(angle: placement.yaw, axis: [0, 1, 0])
        root.scale = SIMD3<Float>(repeating: placement.scale)
        handle.scale = SIMD3<Float>(repeating: 1 / placement.scale)
        pivotMarker.scale = SIMD3<Float>(repeating: 1 / placement.scale)
        applyMarkScale()
        updateCornerBallSize()
        // Measurements and voids are only taken and shown at real size.
        marksRoot.isEnabled = atRealSize
        stairRoot.isEnabled = atRealSize
        if !atRealSize {
            if selection != nil { selection = nil }
            if toolActive { setTool(.none) }
        }
    }

    private static func normalized(_ yaw: Float) -> Float {
        let wrapped = remainder(yaw, 2 * .pi)
        return wrapped <= -.pi ? wrapped + 2 * .pi : wrapped
    }

    // MARK: World tracking

    func startTracking() {
        guard trackingTask == nil else { return }
        guard WorldTrackingProvider.isSupported else {
            // Nothing could ever locate the saved placement (Simulator), so show it as saved.
            if isSearching { setStatus(.placed) }
            return
        }
        let reconstructs = SceneReconstructionProvider.isSupported
        let providers: [any DataProvider] = reconstructs ? [worldTracking, sceneReconstruction] : [worldTracking]
        trackingTask = Task {
            do {
                try await session.run(providers)
            } catch {
                if isSearching { setStatus(.placed) }
                return
            }
            // The search is timed from when tracking starts, not from app launch.
            if isSearching { setStatus(.searching(since: Date())) }
            if reconstructs {
                Task {
                    for await update in sceneReconstruction.anchorUpdates {
                        await scanMesh.apply(update)
                        maintainScanAnchors()
                    }
                }
            }
            Task {
                // Providers pause while the immersive space is closed; a scan cleared in that state
                // gets its first pin when tracking resumes.
                for await event in session.events {
                    if case .dataProviderStateChanged(_, .running, _) = event {
                        await ensureScanAnchors()
                        await locatePlacement()
                    }
                }
            }
            Task {
                await ensureScanAnchors()
                await locatePlacement()
            }
            Task {
                for await availability in worldTracking.worldAnchorSharingAvailability {
                    anchorSharingAvailable = availability == .available
                }
            }
            for await update in worldTracking.anchorUpdates {
                let m = update.anchor.originFromAnchorTransform
                var removed = false
                if case .removed = update.event { removed = true }
                let tracked = update.anchor.isTracked && !removed
                if scanMesh.hasAnchor(update.anchor.id) {
                    scanMesh.anchorUpdated(update.anchor.id, originFromAnchor: m, tracked: tracked)
                    syncScanFrame()
                    continue
                }
                if update.anchor.id == placement.anchorID {
                    houseAnchorTracked = tracked
                    if tracked, !isGesturing { adoptAnchorPose(m) }
                    continue
                }
                if tracked, update.anchor.isSharedWithNearbyParticipants {
                    onSharedAnchor?(update.anchor.id, m)
                }
            }
        }
    }

    // MARK: Scan

    private static let scanAnchorSpacing: Float = 3

    /// Drops world anchors that no longer place anything, then re-reads the tracked state of the
    /// scan pins, which may already be tracked and produce no new update. A scan without pins gets
    /// its first one at the wearer's position.
    private func ensureScanAnchors() async {
        guard worldTracking.state == .running else { return }
        let stale = ScanStore.staleAnchors()
        for id in stale { try? await worldTracking.removeAnchor(forID: id) }
        ScanStore.setStaleAnchors(ScanStore.staleAnchors().filter { !stale.contains($0) })
        scanAnchorAddFailed = false
        let ids = scanMesh.anchorIDs
        guard !ids.isEmpty else {
            maintainScanAnchors()
            return
        }
        guard let known = await worldTracking.allAnchors else { return }
        for anchor in known where ids.contains(anchor.id) {
            scanMesh.anchorUpdated(anchor.id, originFromAnchor: anchor.originFromAnchorTransform, tracked: anchor.isTracked)
        }
        syncScanFrame()
    }

    /// The model's anchor may already be tracked when tracking starts, in which case no update
    /// arrives for it; read it directly, as `ensureScanAnchors` does for the scan pins.
    private func locatePlacement() async {
        guard worldTracking.state == .running, let id = placement.anchorID,
              let anchor = await worldTracking.allAnchors?.first(where: { $0.id == id }) else { return }
        houseAnchorTracked = anchor.isTracked
        if anchor.isTracked, !isGesturing { adoptAnchorPose(anchor.originFromAnchorTransform) }
    }

    /// Adds a pin when the scan has none, or once the wearer is farther than the spacing from
    /// every known pin, so no cell is far from the pin placing it. Only one add is in flight at a
    /// time, and a refused add is not retried until tracking next resumes or the scan is cleared.
    private func maintainScanAnchors() {
        guard !creatingScanAnchor, !scanAnchorAddFailed, let planned = plannedScanAnchor() else { return }
        creatingScanAnchor = true
        let epoch = scanEpoch
        Task {
            defer { creatingScanAnchor = false }
            let anchor = WorldAnchor(originFromAnchorTransform: planned.originFromAnchor)
            guard (try? await worldTracking.addAnchor(anchor)) != nil else {
                scanAnchorAddFailed = true
                return
            }
            guard scanEpoch == epoch else {
                try? await worldTracking.removeAnchor(forID: anchor.id)
                return
            }
            scanMesh.addAnchor(id: anchor.id, scanFromAnchor: planned.scanFromAnchor, originFromAnchor: planned.originFromAnchor)
        }
    }

    /// The first pin defines the scan frame; later pins record where they sit in it, as estimated
    /// from the tracked pin nearest the wearer, and never change.
    private func plannedScanAnchor() -> (originFromAnchor: simd_float4x4, scanFromAnchor: simd_float4x4)? {
        guard let pose = devicePose() else { return nil }
        let position = Self.translation(pose)
        var originFromAnchor = matrix_identity_float4x4
        originFromAnchor.columns.3 = SIMD4(position, 1)
        if scanMesh.anchorIDs.isEmpty { return (originFromAnchor, matrix_identity_float4x4) }
        guard let originFromScan = scanMesh.originFromScan(near: position),
              scanMesh.pinPoses.allSatisfy({ simd_distance(Self.translation($0.originFromPin), position) > Self.scanAnchorSpacing })
        else { return nil }
        return (originFromAnchor, originFromScan.inverse * originFromAnchor)
    }

    func clearScan() {
        ScanStore.clear()
        ScanStore.addStaleAnchors(scanMesh.anchorIDs)
        scanEpoch += 1
        scanMesh.clear()
        // The next scan starts a new frame, which the old record means nothing in.
        placement.scanFromModel = nil
        placement.save()
        pendingSharedPlacement = nil
        Task { await ensureScanAnchors() }
        onScanCleared?()
    }

    // MARK: Sharing with other headsets (driven by SiteSharing)

    /// Called with `scanFromModel` whenever the house is placed by hand at real size while its
    /// pose in the scan frame is known: `commitPlacement` and the first `recordScanFrame`.
    var onPlacementPublished: ((simd_float4x4) -> Void)?

    /// Called after Clear scan, once the own scan is gone.
    var onScanCleared: (() -> Void)?

    /// Places the house where another headset put it, given in this headset's scan frame, and
    /// re-pins its world anchor. Never calls `onPlacementPublished`.
    func adoptSharedPlacement(scanFromModel: simd_float4x4) {
        guard !isGesturing else { return }
        guard atRealSize else {
            pendingSharedPlacement = scanFromModel
            return
        }
        pendingSharedPlacement = nil
        placement.scanFromModel = ScanMesh.columns(scanFromModel)
        guard let originFromScan = scanMesh.originFromScan(nearScan: Self.translation(scanFromModel)) else {
            // While searching, `syncScanFrame` restores the house from the saved record once pins track.
            if !isSearching { pendingSharedPlacement = scanFromModel }
            placement.save()
            return
        }
        let m = originFromScan * scanFromModel
        placement.position = Self.translation(m)
        placement.yaw = Self.normalized(atan2(m.columns.2.x, m.columns.2.z))
        applyPlacement()
        pushVoids()
        if isSearching { found(via: .scan) }
        placement.save()
        repin()
    }

    /// A shared placement waiting for 1:1 scale or for the scan to align.
    private var pendingSharedPlacement: simd_float4x4?

    /// The wearer's head in the scan frame; nil while not tracking or the scan is not aligned.
    func scanFromHead() -> simd_float4x4? {
        guard let pose = devicePose(), let originFromScan = scanMesh.originFromScan(near: Self.translation(pose)) else { return nil }
        return originFromScan.inverse * pose
    }

    /// Shared world anchors can be created now (a nearby SharePlay session is active).
    private(set) var anchorSharingAvailable = false

    /// Creates a world anchor shared with nearby SharePlay participants at the wearer's head,
    /// upright and turned to their heading. Nil when sharing is unavailable or the add failed.
    /// Session-only: never saved.
    func addSharedAnchor() async -> (id: UUID, originFromAnchor: simd_float4x4)? {
        guard anchorSharingAvailable, let pose = devicePose() else { return nil }
        var transform = simd_float4x4(Self.yawRotation(pose))
        transform.columns.3 = SIMD4(Self.translation(pose), 1)
        let anchor = WorldAnchor(originFromAnchorTransform: transform, sharedWithNearbyParticipants: true)
        guard (try? await worldTracking.addAnchor(anchor)) != nil else { return nil }
        return (anchor.id, transform)
    }

    /// A world anchor shared with nearby participants (one this headset created, or another
    /// headset's) is tracked at this pose. Shared anchors carry the same id on every headset.
    var onSharedAnchor: ((UUID, simd_float4x4) -> Void)?

    // MARK: Anchor markers

    private static let trackedMarkerMaterial = UnlitMaterial(color: .systemGreen)
    private static let estimatedMarkerMaterial = UnlitMaterial(color: .systemGray)

    /// A post standing on an anchor; with `arrow`, a cone at the top points along the model's −Z
    /// (Revit north). No collider or input target, so it never takes a pinch.
    private static func post(height: Float, arrow: Bool) -> Entity {
        let post = Entity()
        let pole = ModelEntity(mesh: .generateCylinder(height: height, radius: 0.012), materials: [estimatedMarkerMaterial])
        pole.position.y = height / 2
        post.addChild(pole)
        let cap = ModelEntity(mesh: .generateSphere(radius: 0.035), materials: [estimatedMarkerMaterial])
        cap.position.y = height
        post.addChild(cap)
        if arrow {
            let cone = ModelEntity(mesh: .generateCone(height: 0.2, radius: 0.05), materials: [estimatedMarkerMaterial])
            cone.position = [0, height, -0.12]
            cone.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            post.addChild(cone)
        }
        return post
    }

    private static func paintMarker(_ post: Entity, tracked: Bool) {
        for case let part as ModelEntity in post.children {
            part.model?.materials = [tracked ? trackedMarkerMaterial : estimatedMarkerMaterial]
        }
    }

    /// Places the model's post and one post per scan pin (with its drift correction), green where
    /// visionOS tracks the anchor and grey where it is estimated. A pin corrected by more than 2 cm
    /// carries the size of the correction. Called every frame while the markers are shown.
    func updateAnchorMarkers() {
        guard anchorMarkers.isEnabled else { return }
        housePin.isEnabled = placement.anchorID != nil && !isSearching
        if housePin.isEnabled {
            housePin.transform = Transform(matrix: placementTransform)
            Self.paintMarker(housePin, tracked: houseAnchorTracked)
        }
        let poses = scanMesh.pinPoses
        let ids = Set(poses.map(\.id))
        for (id, marker) in pinMarkers where !ids.contains(id) {
            marker.entity.removeFromParent()
            pinMarkers[id] = nil
        }
        for pose in poses {
            if pinMarkers[pose.id] == nil {
                let entity = Self.post(height: 0.6, arrow: false)
                anchorMarkers.addChild(entity)
                pinMarkers[pose.id] = (entity: entity, tracked: false, label: 0)
            }
            var marker = pinMarkers[pose.id]!
            marker.entity.transform = Transform(matrix: pose.originFromPin)
            if marker.tracked != pose.tracked {
                Self.paintMarker(marker.entity, tracked: pose.tracked)
                marker.tracked = pose.tracked
            }
            let centimetres = pose.correction > 0.02 ? Int((pose.correction * 100).rounded()) : 0
            if marker.label != centimetres {
                marker.entity.findEntity(named: "correction")?.removeFromParent()
                if centimetres > 0 { marker.entity.addChild(Self.correctionLabel(centimetres)) }
                marker.label = centimetres
            }
            pinMarkers[pose.id] = marker
        }
    }

    private static func correctionLabel(_ centimetres: Int) -> Entity {
        let text = ModelEntity(
            mesh: .generateText("↔ \(centimetres) cm", extrusionDepth: 0.002, font: .systemFont(ofSize: 0.06, weight: .semibold)),
            materials: [UnlitMaterial(color: .white)])
        text.position.x = -text.visualBounds(relativeTo: text).center.x
        let label = Entity()
        label.name = "correction"
        label.position.y = 0.7
        label.components.set(BillboardComponent())
        label.addChild(text)
        return label
    }

    private static func translation(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    private func devicePose() -> simd_float4x4? {
        guard worldTracking.state == .running else { return nil }
        return worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())?.originFromAnchorTransform
    }

    private func pinWorldAnchor() async {
        guard worldTracking.state == .running else { return }
        let old = placement.anchorID
        placement.anchorID = nil
        houseAnchorTracked = false
        let anchor = WorldAnchor(originFromAnchorTransform: placementTransform)
        if let old {
            try? await worldTracking.removeAnchor(forID: old)
        }
        do {
            try await worldTracking.addAnchor(anchor)
            placement.anchorID = anchor.id
            houseAnchorTracked = true
        } catch {
            placement.anchorID = nil
        }
        placement.save()
    }
}

extension Placement {
    /// One placement for the property, shared by every model.
    static let key = "placement"

    static func load() -> Placement? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Placement.self, from: data)
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }
}
