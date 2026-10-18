import Foundation

/// One remembered scene-reconstruction patch. `transform` is column-major and relative to the
/// project's scan world anchor, so the patch lands in the same place in a later session once
/// visionOS has re-located that anchor.
struct ScanPatch: Codable, Equatable {
    var id: UUID
    var transform: [Float]
    var vertices: Data
    var indices: Data
}

/// Scans kept on the device, one directory per project beside `ModelLibrary.root`.
enum ScanStore {
    private struct AnchorFile: Codable {
        var anchorID: UUID
    }

    static let root: URL = {
        var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "scans", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    static func load(project: String) -> (anchorID: UUID?, patches: [ScanPatch]) {
        let dir = directory(project)
        let anchorID = (try? Data(contentsOf: dir.appending(path: "anchor.json")))
            .flatMap { try? JSONDecoder().decode(AnchorFile.self, from: $0) }?.anchorID
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = PropertyListDecoder()
        let patches = files
            .filter { $0.pathExtension == "patch" }
            .compactMap { try? decoder.decode(ScanPatch.self, from: Data(contentsOf: $0)) }
        return (anchorID, patches)
    }

    static func save(_ patch: ScanPatch, project: String) {
        let dir = directory(project)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try? encoder.encode(patch).write(to: dir.appending(path: "\(patch.id.uuidString).patch"), options: .atomic)
    }

    static func saveAnchor(_ id: UUID, project: String) {
        let dir = directory(project)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(AnchorFile(anchorID: id)).write(to: dir.appending(path: "anchor.json"), options: .atomic)
    }

    static func remove(id: UUID, project: String) {
        try? FileManager.default.removeItem(at: directory(project).appending(path: "\(id.uuidString).patch"))
    }

    static func clear(project: String) {
        try? FileManager.default.removeItem(at: directory(project))
    }

    private static func directory(_ project: String) -> URL {
        root.appending(path: project, directoryHint: .isDirectory)
    }
}
