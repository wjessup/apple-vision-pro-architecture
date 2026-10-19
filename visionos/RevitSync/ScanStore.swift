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

/// The property's one scan, shared by every model, kept beside `ModelLibrary.root` in `scans/site/`:
/// `anchors.json` plus `cells/<ix>_<iy>_<iz>.cell`.
enum ScanStore {
    struct Loaded {
        var anchors: [ScanAnchorRecord] = []
        var cells: [CellKey: ScanCellRecord] = [:]
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
    /// queued for removal from world tracking.
    static func load() -> Loaded {
        let dir = directory
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        if files.contains(where: { $0.lastPathComponent == "anchor.json" || $0.pathExtension == "patch" }) {
            if let legacy = (try? Data(contentsOf: dir.appending(path: "anchor.json")))
                .flatMap({ try? JSONDecoder().decode(LegacyAnchorFile.self, from: $0) })?.anchorID {
                addStaleAnchors([legacy])
            }
            try? FileManager.default.removeItem(at: dir)
            return Loaded()
        }
        var loaded = Loaded()
        loaded.anchors = (try? Data(contentsOf: dir.appending(path: "anchors.json")))
            .flatMap { try? JSONDecoder().decode([ScanAnchorRecord].self, from: $0) } ?? []
        let cellFiles = (try? FileManager.default.contentsOfDirectory(at: cells, includingPropertiesForKeys: nil)) ?? []
        let decoder = PropertyListDecoder()
        for file in cellFiles where file.pathExtension == "cell" {
            guard let key = CellKey(fileName: file.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(ScanCellRecord.self, from: data) else { continue }
            loaded.cells[key] = record
        }
        return loaded
    }

    static func saveAnchors(_ anchors: [ScanAnchorRecord]) {
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(anchors).write(to: dir.appending(path: "anchors.json"), options: .atomic)
    }

    static func save(_ cell: ScanCellRecord, key: CellKey) {
        let dir = cells
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try? encoder.encode(cell).write(to: dir.appending(path: "\(key.fileName).cell"), options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Scans used to be kept per model. The kept model's scan becomes the site scan; every other
    /// model's pins are queued for removal from world tracking and its directory deleted.
    static func adoptLegacyScans(keeping project: String?) {
        let fm = FileManager.default
        if let project { try? fm.moveItem(at: root.appending(path: project, directoryHint: .isDirectory), to: directory) }
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for dir in dirs where dir.lastPathComponent != "site"
            && (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let anchors = (try? Data(contentsOf: dir.appending(path: "anchors.json")))
                .flatMap { try? JSONDecoder().decode([ScanAnchorRecord].self, from: $0) }?.map(\.id) ?? []
            let legacy = (try? Data(contentsOf: dir.appending(path: "anchor.json")))
                .flatMap { try? JSONDecoder().decode(LegacyAnchorFile.self, from: $0) }?.anchorID
            addStaleAnchors(anchors + (legacy.map { [$0] } ?? []))
            try? fm.removeItem(at: dir)
        }
    }

    // World anchors that no longer place any scan. They can only be removed while tracking runs,
    // so the ids wait on disk until then and survive a quit in between.

    static func staleAnchors() -> [UUID] {
        (try? Data(contentsOf: staleFile)).flatMap { try? JSONDecoder().decode([UUID].self, from: $0) } ?? []
    }

    static func addStaleAnchors(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        setStaleAnchors(staleAnchors() + ids)
    }

    static func setStaleAnchors(_ ids: [UUID]) {
        if ids.isEmpty {
            try? FileManager.default.removeItem(at: staleFile)
        } else {
            try? JSONEncoder().encode(ids).write(to: staleFile, options: .atomic)
        }
    }

    private static var staleFile: URL { root.appending(path: "stale-anchors.json") }

    static var directory: URL { root.appending(path: "site", directoryHint: .isDirectory) }

    private static var cells: URL { directory.appending(path: "cells", directoryHint: .isDirectory) }
}
