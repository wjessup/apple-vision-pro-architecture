import RealityKit
import SwiftUI

struct ImmersiveView: View {
    @Environment(AppModel.self) private var model

    @State private var dragStart: SIMD3<Float>?
    @State private var scaleStart: Float?
    @State private var yawStart: Float?

    private var scene: SceneController { model.scene }

    var body: some View {
        RealityView { content in
            content.add(scene.root)
            content.add(scene.scanMesh.root)
            scene.startTracking()
        }
        .gesture(drag)
        .simultaneousGesture(magnify)
        .simultaneousGesture(rotate)
        .onAppear { model.immersiveOpen = true }
        .onDisappear { model.immersiveOpen = false }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0.0, coordinateSpace: .global)
            .targetedToEntity(scene.root)
            .onChanged { value in
                guard !model.locked else { return }
                if dragStart == nil {
                    dragStart = scene.root.position(relativeTo: nil)
                    scene.isGesturing = true
                }
                let offset = value.convert(value.translation3D, from: .local, to: .scene)
                scene.setPosition(dragStart! + offset)
            }
            .onEnded { _ in
                guard dragStart != nil else { return }
                dragStart = nil
                finishGesture()
            }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .targetedToEntity(scene.root)
            .onChanged { value in
                guard !model.locked else { return }
                if scaleStart == nil {
                    scaleStart = scene.placement.scale
                    scene.isGesturing = true
                }
                scene.setScale(scaleStart! * Float(value.magnification))
            }
            .onEnded { _ in
                guard scaleStart != nil else { return }
                scaleStart = nil
                finishGesture()
            }
    }

    private var rotate: some Gesture {
        RotateGesture3D(constrainedToAxis: .y)
            .targetedToEntity(scene.root)
            .onChanged { value in
                guard !model.locked else { return }
                if yawStart == nil {
                    yawStart = scene.placement.yaw
                    scene.isGesturing = true
                }
                let sign: Float = value.rotation.axis.y < 0 ? -1 : 1
                scene.setYaw(yawStart! + sign * Float(value.rotation.angle.radians))
            }
            .onEnded { _ in
                guard yawStart != nil else { return }
                yawStart = nil
                finishGesture()
            }
    }

    private func finishGesture() {
        guard dragStart == nil, scaleStart == nil, yawStart == nil else { return }
        scene.isGesturing = false
        scene.commitPlacement()
    }
}
