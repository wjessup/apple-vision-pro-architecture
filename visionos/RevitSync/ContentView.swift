import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                serverSection
                if model.connection == .connected || !model.projectRows.isEmpty {
                    projectSection
                }
                if model.selectedProjectID != nil {
                    revisionSection
                    placementSection
                }
            }
            .navigationTitle("Revit Sync")
            .toolbar {
                ToolbarItem(placement: .bottomOrnament) {
                    immersiveButton
                }
            }
        }
        .task { model.startDiscovery() }
        .task { await model.sync() }
        .task {
            if !model.serverURLString.isEmpty { await model.connect() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, case .failed = model.connection else { return }
            Task { await model.connect() }
        }
    }

    private var serverSection: some View {
        @Bindable var model = model
        return Section("Server") {
            ForEach(model.discovered) { server in
                Button {
                    Task { await model.connect(to: server.url) }
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text(server.name)
                            Text(server.url.absoluteString).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "desktopcomputer")
                    }
                }
            }
            HStack {
                TextField("http://192.168.1.20:8787", text: $model.serverURLString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { Task { await model.connect() } }
                Button("Connect") { Task { await model.connect() } }
                    .disabled(model.connection == .connecting)
            }
            connectionRow
        }
    }

    @ViewBuilder
    private var connectionRow: some View {
        switch model.connection {
        case .disconnected:
            Label("Not connected", systemImage: "circle")
        case .connecting:
            Label("Connecting…", systemImage: "circle.dotted")
        case .connected:
            Label("Connected, listening for updates", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var projectSection: some View {
        Section {
            if model.projectRows.isEmpty {
                Text("No projects yet. Press “View in Apple Vision Pro” in Revit, or run tools/push_model.py.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.projectRows) { project in
                Button {
                    Task { await model.select(projectID: project.id) }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(project.name)
                            Text(subtitle(project)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if project.id == model.selectedProjectID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } header: {
            Text("Project")
        } footer: {
            if model.connection != .connected {
                Text("Showing models saved on this device. Connect to the server to download new projects or updates.")
            }
        }
    }

    private func subtitle(_ project: ProjectRow) -> String {
        guard let saved = project.savedRevision else { return "Revision \(project.revision) · not downloaded" }
        return saved == project.revision
            ? "Revision \(saved) · on this device"
            : "Revision \(saved) on this device · \(project.revision) on server"
    }

    private var revisionSection: some View {
        @Bindable var model = model
        return Section("Revision") {
            if let label = model.phase.label {
                HStack {
                    ProgressView()
                    Text(label)
                }
            } else if let revision = model.loadedRevision {
                Label("Showing revision \(revision) · \(model.scene.partitionCount) parts", systemImage: "cube")
            }
            if let pending = model.pendingRevision {
                HStack {
                    Label("Revision \(pending) is ready", systemImage: "arrow.down.circle")
                    Spacer()
                    Button("Load now") { Task { await model.loadPending() } }
                }
            }
            Toggle("Reload automatically", isOn: $model.autoReload)
            Button("Sync now") { Task { await model.sync() } }
                .disabled(model.phase != .idle || model.connection != .connected)
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    private var placementSection: some View {
        @Bindable var model = model
        return Section("Placement") {
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

    private var immersiveButton: some View {
        Button {
            Task {
                if model.immersiveOpen {
                    await dismissImmersiveSpace()
                } else {
                    await openImmersiveSpace(id: AppModel.immersiveSpaceID)
                }
            }
        } label: {
            Label(model.immersiveOpen ? "Hide model" : "Show model in room",
                  systemImage: model.immersiveOpen ? "eye.slash" : "eye")
        }
        .disabled(model.selectedProjectID == nil)
    }
}
