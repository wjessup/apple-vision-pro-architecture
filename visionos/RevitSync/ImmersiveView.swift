import RealityKit
import SwiftUI

struct ImmersiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase

    @State private var dragStart: SIMD3<Float>?
    @State private var draggedCorner: Int?
    @State private var scaleStart: Float?
    @State private var yawStart: Float?
    @State private var panelUpdates: EventSubscription?

    private var scene: SceneController { model.scene }

    var body: some View {
        RealityView { content, attachments in
            content.add(scene.root)
            content.add(scene.scanMesh.root)
            scene.startTracking()
            scene.resetPanel()
            if let panel = attachments.entity(for: "tools") {
                content.add(panel)
                panelUpdates = content.subscribe(to: SceneEvents.Update.self) { event in
                    scene.updatePanel(panel, deltaTime: Float(event.deltaTime), follow: model.followMe)
                    scene.updateCornerBallSize()
                }
            }
        } update: { _, attachments in
            for measurement in scene.measurements {
                guard let label = attachments.entity(for: measurement.id),
                      let anchor = scene.labelAnchor(id: measurement.id),
                      label.parent !== anchor else { continue }
                anchor.children.filter { $0 !== label }.forEach { $0.removeFromParent() }
                label.components.set(BillboardComponent())
                anchor.addChild(label)
            }
        } attachments: {
            Attachment(id: "tools") {
                // visionOS can't move an open window, but a reopened one appears in front of the
                // user. Attachments don't reliably inherit the scene's environment, so the window
                // actions are captured here.
                ToolsPanel(bringWindow: {
                    dismissWindow(id: AppModel.mainWindowID)
                    openWindow(id: AppModel.mainWindowID)
                }).environment(model)
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
        .simultaneousGesture(tap)
        .onAppear {
            model.immersiveOpen = true
            scene.setMeasuring(true)
        }
        // The main window may be closed while the space stays open, so the space saves too.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { scene.scanMesh.saveLive() }
        }
        .onDisappear {
            model.immersiveOpen = false
            scene.scanMesh.flushLive()
            scene.setMeasuring(false)
            panelUpdates?.cancel()
        }
    }

    private var measureTap: some Gesture {
        SpatialTapGesture()
            .targetedToEntity(scene.root)
            .onEnded { value in
                guard scene.measuring, isDescendant(value.entity, of: scene.model) else { return }
                let point = value.convert(value.location3D, from: .local, to: .scene)
                scene.addMeasurePoint(scene.root.convert(position: point, from: nil))
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0.0, coordinateSpace: .global)
            .targetedToAnyEntity()
            .onChanged { value in
                guard !model.locked, !scene.measuring else { return }
                if dragStart == nil {
                    if let corner = scene.cornerIndex(of: value.entity), let start = scene.cornerWorld(corner) {
                        guard scene.cornerState(corner) == .free else { return scene.warnCornerLocked() }
                        draggedCorner = corner
                        dragStart = start
                    } else if isDescendant(value.entity, of: scene.root), !isDescendant(value.entity, of: scene.measureRoot) {
                        guard !scene.cornerLocked else { return scene.warnCornerLocked() }
                        dragStart = scene.root.position(relativeTo: nil)
                    } else {
                        return
                    }
                    scene.isGesturing = true
                }
                let target = dragStart! + value.convert(value.translation3D, from: .local, to: .scene)
                if let draggedCorner {
                    scene.dragCorner(draggedCorner, to: target)
                } else {
                    scene.setPosition(target)
                }
            }
            .onEnded { _ in
                guard dragStart != nil else { return }
                dragStart = nil
                draggedCorner = nil
                finishGesture()
            }
    }

    private var tap: some Gesture {
        SpatialTapGesture()
            .targetedToAnyEntity()
            .onEnded { value in
                guard !model.locked, !scene.measuring, let corner = scene.cornerIndex(of: value.entity) else { return }
                scene.toggleCornerLock(corner)
            }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .targetedToEntity(scene.root)
            .onChanged { value in
                guard !model.locked, !scene.measuring, model.placementMode == .basic, !scene.scaleLocked else { return }
                guard !scene.cornerLocked else { return scene.warnCornerLocked() }
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
                guard !scene.cornerLocked else { return scene.warnCornerLocked() }
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

    // Drag and tap target any entity (corner balls), so attachments such as the tools panel and
    // measurement labels must be filtered out by ancestry.
    private func isDescendant(_ entity: Entity, of ancestor: Entity) -> Bool {
        var current: Entity? = entity
        while let e = current {
            if e === ancestor { return true }
            current = e.parent
        }
        return false
    }

    private func finishGesture() {
        guard dragStart == nil, scaleStart == nil, yawStart == nil else { return }
        scene.isGesturing = false
        scene.commitPlacement()
    }
}
