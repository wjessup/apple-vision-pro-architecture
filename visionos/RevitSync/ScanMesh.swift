import ARKit
import RealityKit

@MainActor
final class ScanMesh {
    let root = Entity()

    var isVisible = false {
        didSet { patches.values.forEach { $0.wireframe.isEnabled = isVisible } }
    }

    private var patches: [UUID: (occluder: ModelEntity, wireframe: ModelEntity)] = [:]

    private let wireframeMaterial: UnlitMaterial = {
        var material = UnlitMaterial(color: .systemCyan)
        material.triangleFillMode = .lines
        // Drawn over everything so the whole scan is visible, including patches hidden behind the model.
        material.readsDepth = false
        return material
    }()

    init() {
        root.name = "scanMesh"
    }

    func apply(_ update: AnchorUpdate<MeshAnchor>) async {
        let anchor = update.anchor
        switch update.event {
        case .added, .updated:
            guard let mesh = try? await MeshResource(from: anchor) else { return }
            let patch = patches[anchor.id] ?? addPatch(id: anchor.id)
            patch.occluder.model = ModelComponent(mesh: mesh, materials: [OcclusionMaterial()])
            patch.wireframe.model = ModelComponent(mesh: mesh, materials: [wireframeMaterial])
            patch.occluder.transform = Transform(matrix: anchor.originFromAnchorTransform)
        case .removed:
            patches.removeValue(forKey: anchor.id)?.occluder.removeFromParent()
        }
    }

    private func addPatch(id: UUID) -> (occluder: ModelEntity, wireframe: ModelEntity) {
        let occluder = ModelEntity()
        let wireframe = ModelEntity()
        wireframe.isEnabled = isVisible
        occluder.addChild(wireframe)
        root.addChild(occluder)
        patches[id] = (occluder, wireframe)
        return (occluder, wireframe)
    }
}
