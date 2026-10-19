import SwiftUI

struct ToolsPanel: View {
    @Environment(AppModel.self) private var model
    let bringWindow: () -> Void

    var body: some View {
        let scene = model.scene
        VStack(alignment: .leading, spacing: 8) {
            Button("Bring window here", systemImage: "macwindow", action: bringWindow)
            Toggle("Measure", isOn: Binding(get: { scene.measuring }, set: { scene.setMeasuring($0) }))
                .disabled(!scene.atRealSize)
            if let measureCaption {
                Text(measureCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 260)
        .glassBackgroundEffect()
    }

    private var measureCaption: String? {
        let scene = model.scene
        if !scene.atRealSize { return "Switch to 1:1 Real size to measure" }
        guard scene.measuring else { return nil }
        if scene.preparingMeasure { return "Preparing…" }
        return scene.pendingPoint == nil ? "Pinch a spot on the model…" : "Pinch a second spot…"
    }
}

struct MeasurementLabel: View {
    @Environment(AppModel.self) private var model
    let measurement: Measurement

    var body: some View {
        let scene = model.scene
        let selected = scene.selectedMeasurement == measurement.id
        HStack(spacing: 8) {
            Button(feetAndInches(meters: measurement.meters)) {
                scene.selectedMeasurement = selected ? nil : measurement.id
            }
            .buttonStyle(.borderless)
            if selected {
                Button(role: .destructive) {
                    scene.deleteMeasurement(id: measurement.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .font(.title3.monospacedDigit())
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(selected ? AnyShapeStyle(Color.yellow.opacity(0.35)) : AnyShapeStyle(.regularMaterial), in: Capsule())
    }
}

struct PlacementControls: View {
    @Environment(AppModel.self) private var model
    @State private var nudgeStart: SIMD3<Float>?
    @State private var nudge = SIMD3<Float>.zero

    var body: some View {
        @Bindable var model = model
        let scene = model.scene
        let cornerLocked = !scene.lockedCorners.isEmpty
        Picker("Mode", selection: $model.placementMode) {
            ForEach(PlacementMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .disabled(model.locked)
        Picker("Scale", selection: Binding(
            get: { ScalePreset.allCases.first { abs($0.rawValue - model.scene.placement.scale) < 0.0001 } },
            set: { preset in
                guard let preset else { return }
                model.scene.setScale(preset.rawValue)
                model.scene.commitPlacement()
            })) {
            ForEach(ScalePreset.allCases) { preset in
                Text(preset.label).tag(Optional(preset))
            }
        }
        .pickerStyle(.segmented)
        .disabled(model.locked || cornerLocked)
        if model.placementMode == .precise {
            preciseControls.disabled(model.locked)
        }
        if model.placementMode == .corners, scene.corners != nil {
            cornerRows.disabled(model.locked)
        }
        Toggle("Lock position", isOn: $model.locked)
        Button("Place in front of me") { scene.placeInFrontOfUser() }
            .disabled(model.locked || cornerLocked || !model.immersiveOpen)
        Text(placementCaption)
            .font(.caption)
            .foregroundStyle(.secondary)
        DisclosureGroup("Advanced") {
            Toggle("Allow free scaling", isOn: Binding(
                get: { !scene.scaleLocked },
                set: { scene.scaleLocked = !$0 }))
            Text("Size normally stays at the scale chosen above. Turn this on to resize by pinching, with the scale slider, or by dragging a second corner.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var cornerRows: some View {
        let scene = model.scene
        return ForEach(Footprint.cornerNames.indices, id: \.self) { index in
            let state = scene.cornerState(index)
            HStack {
                Image(systemName: "circle.fill").foregroundStyle(cornerColor(state))
                Text(Footprint.cornerNames[index])
                Text(state == .locked ? "Locked" : "Free").foregroundStyle(.secondary)
                Spacer()
                Button(state == .locked ? "Unlock" : "Lock") { scene.toggleCornerLock(index) }
                    .buttonStyle(.bordered)
                    .disabled(state == .unavailable)
            }
        }
    }

    private func cornerColor(_ state: CornerState) -> Color {
        switch state {
        case .free: .orange
        case .locked: .green
        case .unavailable: .gray
        }
    }

    private var placementCaption: String {
        if model.locked { return "Locked: pinches won't move the model." }
        let scene = model.scene
        let sizeHint = scene.scaleLocked && abs(scene.placement.scale - ScalePreset.full.rawValue) > 0.0001
            ? " Choose 1:1 Real size to see it at full scale." : ""
        switch model.placementMode {
        case .basic:
            return scene.scaleLocked
                ? "Pinch and drag the blue handle or the model to move it. Pinch with both hands to rotate. Size stays at the scale above." + sizeHint
                : "Pinch and drag the blue handle or the model to move it. Pinch with both hands to scale or rotate."
        case .precise:
            return scene.scaleLocked
                ? "Drag the blue handle to move the base point, or nudge it with the X/Y/Z sliders. Use the slider to rotate around it." + sizeHint
                : "Drag the blue handle to move the base point, or nudge it with the X/Y/Z sliders. Use the sliders to scale and rotate around it."
        case .corners:
            return cornerCaption + (scene.lockedCorners.isEmpty ? sizeHint : "")
        }
    }

    private var cornerCaption: String {
        let scene = model.scene
        guard scene.corners != nil else {
            return scene.partitionCount > 0
                ? "Couldn't find four corners in this model's outline."
                : "Load the model to find its corners."
        }
        let locked = scene.lockedCorners.map { Footprint.cornerNames[$0] }
        switch locked.count {
        case 0:
            return "Drag a corner onto its real-world spot, then tap it to lock."
        case 1:
            let motion = scene.scaleLocked ? "swing" : "swing and size"
            return "\(locked[0]) is locked. Drag another corner to \(motion) the model around \(locked[0]), then tap it to lock."
        default:
            return "Locked by \(locked[0]) and \(locked[1]). Unlock a corner to adjust."
        }
    }

    @ViewBuilder
    private var preciseControls: some View {
        let scene = model.scene
        VStack(alignment: .leading) {
            Text("Scale 1:\(String(format: "%.1f", 1 / scene.placement.scale))")
            if !scene.scaleLocked {
                Slider(
                    value: Binding(
                        get: { Double(log10(scene.placement.scale)) },
                        set: { scene.setScale(Float(pow(10, $0))) }),
                    in: -3...0,
                    onEditingChanged: sliderEditing)
                HStack {
                    stepButton("−1%") { scene.setScale(scene.placement.scale * 0.99) }
                    stepButton("+1%") { scene.setScale(scene.placement.scale * 1.01) }
                }
            }
        }
        VStack(alignment: .leading) {
            Text("Rotation \(String(format: "%.1f", scene.placement.yaw * 180 / .pi))°")
            Slider(
                value: Binding(
                    get: { Double(scene.placement.yaw * 180 / .pi) },
                    set: { scene.setYaw(Float($0) * .pi / 180) }),
                in: -180...180,
                onEditingChanged: sliderEditing)
            HStack {
                stepButton("−1°") { rotate(by: -1) }
                stepButton("−0.1°") { rotate(by: -0.1) }
                stepButton("+0.1°") { rotate(by: 0.1) }
                stepButton("+1°") { rotate(by: 1) }
            }
        }
        ForEach(0..<3, id: \.self) { axis in
            translationControl(axis: axis)
        }
    }

    /// The slider moves up to ±3 m from where the drag began and recentres on release,
    /// so it stays fine-grained wherever the model sits.
    private func translationControl(axis: Int) -> some View {
        let scene = model.scene
        return VStack(alignment: .leading) {
            Text("\(["X", "Y", "Z"][axis]) \(String(format: "%.2f", scene.placement.position[axis] / 0.3048)) ft")
            Slider(
                value: Binding(
                    get: { Double(nudge[axis]) },
                    set: { value in
                        let start = nudgeStart ?? scene.placement.position
                        nudgeStart = start
                        nudge[axis] = Float(value)
                        var position = start
                        position[axis] += Float(value)
                        scene.setPosition(position)
                    }),
                in: -3...3,
                onEditingChanged: { editing in
                    if !editing {
                        nudgeStart = nil
                        nudge = .zero
                    }
                    sliderEditing(editing)
                })
            HStack {
                stepButton("−1 ft") { translate(axis: axis, by: -0.3048) }
                stepButton("−1 in") { translate(axis: axis, by: -0.0254) }
                stepButton("+1 in") { translate(axis: axis, by: 0.0254) }
                stepButton("+1 ft") { translate(axis: axis, by: 0.3048) }
            }
        }
    }

    private func translate(axis: Int, by meters: Float) {
        var position = model.scene.placement.position
        position[axis] += meters
        model.scene.setPosition(position)
    }

    private func rotate(by degrees: Float) {
        model.scene.setYaw(model.scene.placement.yaw + degrees * .pi / 180)
    }

    private func stepButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title) {
            action()
            model.scene.commitPlacement()
        }
        .buttonStyle(.bordered)
    }

    private func sliderEditing(_ editing: Bool) {
        model.scene.isGesturing = editing
        if !editing { model.scene.commitPlacement() }
    }
}
