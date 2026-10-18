import Foundation

/// One world anchor pinning the project's scan frame to the room. `scanFromAnchor` is column-major
/// and fixed at creation; visionOS re-locating any pin in a later session places the whole scan.
struct ScanAnchorRecord: Codable, Equatable {
    var id: UUID
    var scanFromAnchor: [Float]
}

/// One remembered grid cell. Vertices are in the scan frame; `owner` is the pin whose tracked pose
/// places the cell on screen.
struct ScanCellRecord: Codable, Equatable {
    var owner: UUID
    var vertices: Data
    var indices: Data

    init(owner: UUID, geometry: ScanGeometry) {
        self.owner = owner
        vertices = geometry.vertices
        indices = geometry.indices
    }

    var geometry: ScanGeometry { ScanGeometry(vertices: vertices, indices: indices) }
}

/// Scans kept on the device, one directory per project beside `ModelLibrary.root`:
/// `anchors.json` plus `cells/<ix>_<iy>_<iz>.cell`.
enum ScanStore {
    struct Loaded {
        var anchors: [ScanAnchorRecord] = []
        var cells: [CellKey: ScanCellRecord] = [:]
        var legacyAnchorID: UUID?
    }

    private struct LegacyAnchorFile: Codable {
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

    /// A directory written by the single-anchor layout (`anchor.json` + `*.patch`) cannot be
    /// converted, since its patches are only placed by that one anchor: it is removed, and its anchor
    /// id handed back so the caller can drop the world anchor too.
    static func load(project: String) -> Loaded {
        let dir = directory(project)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        if files.contains(where: { $0.lastPathComponent == "anchor.json" || $0.pathExtension == "patch" }) {
            let legacy = (try? Data(contentsOf: dir.appending(path: "anchor.json")))
                .flatMap { try? JSONDecoder().decode(LegacyAnchorFile.self, from: $0) }?.anchorID
            try? FileManager.default.removeItem(at: dir)
            return Loaded(legacyAnchorID: legacy)
        }
        var loaded = Loaded()
        loaded.anchors = (try? Data(contentsOf: dir.appending(path: "anchors.json")))
            .flatMap { try? JSONDecoder().decode([ScanAnchorRecord].self, from: $0) } ?? []
        let cellFiles = (try? FileManager.default.contentsOfDirectory(at: cells(project), includingPropertiesForKeys: nil)) ?? []
        let decoder = PropertyListDecoder()
        for file in cellFiles where file.pathExtension == "cell" {
            guard let key = CellKey(fileName: file.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(ScanCellRecord.self, from: data) else { continue }
            loaded.cells[key] = record
        }
        return loaded
    }

    static func saveAnchors(_ anchors: [ScanAnchorRecord], project: String) {
        let dir = directory(project)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(anchors).write(to: dir.appending(path: "anchors.json"), options: .atomic)
    }

    static func save(_ cell: ScanCellRecord, key: CellKey, project: String) {
        let dir = cells(project)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try? encoder.encode(cell).write(to: dir.appending(path: "\(key.fileName).cell"), options: .atomic)
    }

    static func clear(project: String) {
        try? FileManager.default.removeItem(at: directory(project))
    }

    private static func directory(_ project: String) -> URL {
        root.appending(path: project, directoryHint: .isDirectory)
    }

    private static func cells(_ project: String) -> URL {
        directory(project).appending(path: "cells", directoryHint: .isDirectory)
    }
}
