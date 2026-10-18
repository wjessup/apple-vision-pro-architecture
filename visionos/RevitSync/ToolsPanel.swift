import SwiftUI

struct ToolsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let scene = model.scene
        VStack(alignment: .leading, spacing: 12) {
            PlacementControls()
            Divider()
            Toggle("Measure", isOn: Binding(get: { scene.measuring }, set: { scene.setMeasuring($0) }))
            if scene.measuring {
                Text(scene.preparingMeasure ? "Preparing…" : measureCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Show scan mesh", isOn: $model.showScanMesh)
            Toggle("Follow me", isOn: $model.followMe)
        }
        .padding(24)
        .frame(width: 420)
        .glassBackgroundEffect()
    }

    private var measureCaption: String {
        model.scene.pendingPoint == nil
            ? "Pinch a spot on the model to start a measurement."
            : "Pinch a second spot to finish it."
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

    var body: some View {
        @Bindable var model = model
        Picker("Mode", selection: $model.placementMode) {
            ForEach(PlacementMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
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
        .disabled(model.locked)
        if model.placementMode == .precise {
            preciseControls.disabled(model.locked)
        }
        Toggle("Lock position", isOn: $model.locked)
        Button("Place in front of me") { model.scene.placeInFrontOfUser() }
            .disabled(model.locked || !model.immersiveOpen)
        Text(placementCaption)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var placementCaption: String {
        if model.locked { return "Locked: pinches won't move the model." }
        switch model.placementMode {
        case .basic:
            return "Pinch and drag the blue handle or the model to move it. Pinch with both hands to scale or rotate."
        case .precise:
            return "Drag the blue handle to move the base point. Use the sliders to scale and rotate around it."
        }
    }

    @ViewBuilder
    private var preciseControls: some View {
        let scene = model.scene
        VStack(alignment: .leading) {
            Text("Scale 1:\(String(format: "%.1f", 1 / scene.placement.scale))")
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
