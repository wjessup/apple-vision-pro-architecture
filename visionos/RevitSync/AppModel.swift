import Foundation
import Observation

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

enum SyncPhase: Equatable {
    case idle
    case downloading(String)
    case loading(String)

    var label: String? {
        switch self {
        case .idle: nil
        case .downloading(let name): "Downloading \(name)…"
        case .loading(let name): "Loading \(name)…"
        }
    }
}

struct ProjectRow: Identifiable {
    let id: String
    let name: String
    let revision: Int
    let savedRevision: Int?
}

@MainActor
@Observable
final class AppModel {
    static let immersiveSpaceID = "model"

    var serverURLString: String = UserDefaults.standard.string(forKey: "serverURL") ?? "" {
        didSet { UserDefaults.standard.set(serverURLString, forKey: "serverURL") }
    }
    var discovered: [DiscoveredServer] = []
    var connection: ConnectionState = .disconnected
    var projects: [ProjectSummary] = []
    var selectedProjectID: String? = UserDefaults.standard.string(forKey: "selectedProject") {
        didSet { UserDefaults.standard.set(selectedProjectID, forKey: "selectedProject") }
    }
    var library: [String: Manifest] = ModelLibrary.manifests()
    var manifest: Manifest?
    var loadedRevision: Int?
    var pendingRevision: Int?
    var autoReload = true
    var phase: SyncPhase = .idle
    var lastError: String?
    var immersiveOpen = false
    var locked = false {
        didSet { scene.setLocked(locked) }
    }
    var placementMode = PlacementMode(rawValue: UserDefaults.standard.string(forKey: "placementMode") ?? "") ?? .basic {
        didSet {
            UserDefaults.standard.set(placementMode.rawValue, forKey: "placementMode")
            scene.setMode(placementMode)
        }
    }

    let scene = SceneController()

    init() {
        scene.setMode(placementMode)
    }

    private var client: SyncClient?
    private var eventTask: Task<Void, Never>?
    private var inFlightSync: Task<Void, Never>?
    private let browser = ServerBrowser()

    init() {
        if let id = selectedProjectID, library[id] != nil {
            scene.activate(project: id)
        } else {
            selectedProjectID = nil
            UserDefaults.standard.removeObject(forKey: "selectedProject")
        }
    }

    var projectRows: [ProjectRow] {
        var rows: [String: ProjectRow] = library.mapValues {
            ProjectRow(id: $0.project, name: $0.name, revision: $0.revision, savedRevision: $0.revision)
        }
        if connection == .connected {
            for project in projects {
                rows[project.id] = ProjectRow(id: project.id, name: project.name, revision: project.revision,
                                              savedRevision: library[project.id]?.revision)
            }
        }
        return rows.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func startDiscovery() {
        browser.start { [weak self] servers in
            self?.discovered = servers
        }
    }

    func connect(to url: URL? = nil) async {
        if let url { serverURLString = url.absoluteString }
        guard let base = URL(string: serverURLString.trimmingCharacters(in: .whitespaces)), base.host != nil else {
            connection = .failed("Enter the server address, e.g. http://192.168.1.20:8787")
            return
        }
        eventTask?.cancel()
        connection = .connecting
        lastError = nil
        let client = SyncClient(baseURL: base)
        self.client = client
        do {
            projects = try await client.projects()
            connection = .connected
        } catch {
            connection = .failed(error.localizedDescription)
            return
        }
        eventTask = Task { await listen(client) }
    }

    func select(projectID: String) async {
        guard projectID != selectedProjectID else {
            await sync()
            return
        }
        selectedProjectID = projectID
        scene.activate(project: projectID)
        manifest = nil
        loadedRevision = nil
        pendingRevision = nil
        await sync()
    }

    func sync() async {
        await inFlightSync?.value
        guard let selectedProjectID else { return }
        let task = Task {
            defer { phase = .idle }
            do {
                if loadedRevision == nil, let saved = library[selectedProjectID] {
                    try await apply(saved, client: nil)
                }
                if connection == .connected, let client, projects.contains(where: { $0.id == selectedProjectID }) {
                    try await apply(try await client.manifest(project: selectedProjectID), client: client)
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        inFlightSync = task
        await task.value
        if inFlightSync == task { inFlightSync = nil }
    }

    func loadPending() async {
        pendingRevision = nil
        await sync()
    }

    private func listen(_ client: SyncClient) async {
        do {
            for try await event in client.events() {
                switch event {
                case .hello:
                    await refreshProjects(client)
                    if selectedProjectID != nil {
                        await updated(revision: nil)
                    } else if projects.count == 1 {
                        await select(projectID: projects[0].id)
                    }
                case .sceneUpdated(let project, let revision, _, _):
                    let known = projects.contains { $0.id == project }
                    await refreshProjects(client)
                    if selectedProjectID == nil || !known {
                        await select(projectID: project)
                    } else if project == selectedProjectID {
                        await updated(revision: revision)
                    }
                case .unknown:
                    continue
                }
            }
        } catch {
            if !Task.isCancelled {
                connection = .failed("Lost connection: \(error.localizedDescription)")
            }
        }
    }

    private func refreshProjects(_ client: SyncClient) async {
        if let list = try? await client.projects() { projects = list }
    }

    private func updated(revision: Int?) async {
        if autoReload {
            await sync()
        } else if let revision, revision != loadedRevision {
            pendingRevision = revision
        }
    }

    private func apply(_ manifest: Manifest, client: SyncClient?) async throws {
        let before = scene.loadedPartitions
        let after = Set(manifest.partitions.map(\.id))
        for id in before.keys where !after.contains(id) {
            scene.remove(partitionID: id)
        }
        for partition in manifest.partitions where before[partition.id] != partition.sha256 {
            let file = ModelLibrary.assetURL(project: manifest.project, partition: partition)
            if !FileManager.default.fileExists(atPath: file.path) {
                guard let client else {
                    throw SyncError(message: "Connect to the server to download \(partition.name).")
                }
                phase = .downloading(partition.name)
                try await client.download(project: manifest.project, partition: partition, to: file)
            }
            phase = .loading(partition.name)
            try await scene.replace(partitionID: partition.id, sha256: partition.sha256, fileURL: file)
        }
        try ModelLibrary.save(manifest)
        library[manifest.project] = manifest
        phase = .idle
        self.manifest = manifest
        loadedRevision = manifest.revision
        pendingRevision = nil
        if let index = projects.firstIndex(where: { $0.id == manifest.project }) {
            projects[index] = ProjectSummary(id: manifest.project, name: manifest.name, revision: manifest.revision, updatedAt: projects[index].updatedAt)
        }
    }
}
