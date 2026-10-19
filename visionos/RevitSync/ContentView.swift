import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmClearScan = false

    var body: some View {
        TabView {
            NavigationStack {
                Form {
                    projectSection
                    if model.selectedProjectID != nil {
                        revisionSection
                        placementSection
                        realWorldSection
                    }
                }
                .navigationTitle("Projects")
            }
            .tabItem { Label("Projects", systemImage: "building.2") }

            NavigationStack {
                Form {
                    serverSection
                    Section("About") {
                        LabeledContent("Version", value: Self.appVersion)
                    }
                }
                .navigationTitle("Connection")
            }
            .tabItem { Label("Connection", systemImage: connectionIcon) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.scene.scanMesh.saveLive() }
            guard phase == .active, case .failed = model.connection else { return }
            Task { await model.connect() }
        }
    }

    static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }()

    private var connectionIcon: String {
        switch model.connection {
        case .connected: "wifi"
        case .connecting: "wifi.exclamationmark"
        case .disconnected, .failed: "wifi.slash"
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
                Text(model.connection == .connected
                     ? "No projects yet. Press “View in Apple Vision Pro” in Revit, or run tools/push_model.py."
                     : "No models on this device yet. Connect to a server in the Connection tab.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.projectRows) { project in
                Button {
                    Task {
                        let selecting = Task { await model.select(projectID: project.id) }
                        if !model.immersiveOpen {
                            await openImmersiveSpace(id: AppModel.immersiveSpaceID)
                        }
                        await selecting.value
                    }
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
                Text("Showing models saved on this device. Open the Connection tab to download new projects or updates.")
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
            if model.scene.footprintMismatch {
                Label("This model's ground-floor corners are more than a foot from the house you placed. It is shown at the same spot anyway; check that its Revit file uses the same project base point.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            PlacementControls()
            Toggle("Tools panel follows me", isOn: $model.followMe)
            if model.immersiveOpen {
                Button("Hide model", systemImage: "eye.slash") {
                    Task { await dismissImmersiveSpace() }
                }
            }
        }
    }

    private var realWorldSection: some View {
        @Bindable var model = model
        let scan = model.scene.scanMesh
        return Section("Real world") {
            Toggle("Show scan mesh", isOn: $model.showScanMesh)
            Label(scanStatus, systemImage: "square.grid.3x3")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Clear scan", role: .destructive) { confirmClearScan = true }
                .disabled(scan.patchCount == 0)
                .confirmationDialog("Clear the scan of the property?", isPresented: $confirmClearScan, titleVisibility: .visible) {
                    Button("Clear scan", role: .destructive) { model.scene.clearScan() }
                } message: {
                    Text("Every piece kept is deleted from the headset, for every model. Scanning starts again from where you are.")
                }
            Text("Trees, people and other real things the headset has scanned hide the parts of the model behind them. Pieces you walk away from are kept and saved on the headset, so the scan grows to cover the whole property and comes back next time, wherever you start. Every model shares this scan and the same placement on the property. Turn this on to see the scan as a cyan wireframe; remembered pieces are dimmer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var scanStatus: String {
        let scan = model.scene.scanMesh
        let count = "\(scan.patchCount) piece\(scan.patchCount == 1 ? "" : "s") kept"
        return scan.isAligned || scan.rememberedCount == 0 ? count : "\(count) · aligning to previous scan…"
    }
}
