import RealityKit
import SwiftUI

struct ImmersiveView: View {
    @Environment(AppModel.self) private var model

    @State private var dragStart: SIMD3<Float>?
    @State private var scaleStart: Float?
    @State private var yawStart: Float?
    @State private var panelUpdates: EventSubscription?

    private var scene: SceneController { model.scene }

    var body: some View {
        RealityView { content, attachments in
            content.add(scene.root)
            content.add(scene.scanMesh.root)
            scene.startTracking()
            if let panel = attachments.entity(for: "tools") {
                content.add(panel)
                panelUpdates = content.subscribe(to: SceneEvents.Update.self) { event in
                    scene.updatePanel(panel, deltaTime: Float(event.deltaTime), follow: model.followMe)
                }
            }
        } update: { _, attachments in
            for measurement in scene.measurements {
                guard let label = attachments.entity(for: measurement.id),
                      let anchor = scene.labelAnchor(id: measurement.id),
                      label.parent !== anchor else { continue }
                label.components.set(BillboardComponent())
                anchor.addChild(label)
            }
        } attachments: {
            Attachment(id: "tools") {
                ToolsPanel().environment(model)
            }
            ForEach(scene.measurements) { measurement in
                Attachment(id: measurement.id) {
                    MeasurementLabel(measurement: measurement).environment(model)
                }
            }
        }
        .gesture(drag)
        .simultaneousGesture(magnify)
        .simultaneousGesture(rotate)
        .simultaneousGesture(measureTap)
        .onAppear { model.immersiveOpen = true }
        .onDisappear {
            model.immersiveOpen = false
            scene.setMeasuring(false)
            panelUpdates?.cancel()
        }
    }

    private var measureTap: some Gesture {
        SpatialTapGesture()
            .targetedToEntity(scene.root)
            .onEnded { value in
                guard scene.measuring else { return }
                let point = value.convert(value.location3D, from: .local, to: .scene)
                scene.addMeasurePoint(scene.root.convert(position: point, from: nil))
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0.0, coordinateSpace: .global)
            .targetedToEntity(scene.root)
            .onChanged { value in
                guard !model.locked, !scene.measuring else { return }
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
                guard !model.locked, !scene.measuring, model.placementMode == .basic else { return }
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
                guard !model.locked, !scene.measuring, model.placementMode == .basic else { return }
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
