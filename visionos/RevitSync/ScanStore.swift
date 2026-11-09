import Foundation

/// One world anchor pinning the project's scan frame to the room. `scanFromAnchor` is column-major
/// and fixed at creation; visionOS re-locating any pin in a later session places the whole scan.
struct ScanAnchorRecord: Codable, Equatable {
    var id: UUID
    var scanFromAnchor: [Float]
}

/// One remembered grid cell. Vertices are in the scan frame; `owner` is the pin whose tracked pose
/// places the cell on screen. `revision` orders this headset's cell writes for sharing with other
/// headsets; `scannedAt` is when the cell was last written. Cells saved before sharing existed
/// load with revision 0 and the file's modification date.
struct ScanCellRecord: Codable, Equatable {
    var owner: UUID
    var vertices: Data
    var indices: Data
    var revision: Int
    var scannedAt: Date

    init(owner: UUID, geometry: ScanGeometry, revision: Int, scannedAt: Date) {
        self.owner = owner
        vertices = geometry.vertices
        indices = geometry.indices
        self.revision = revision
        self.scannedAt = scannedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decode(UUID.self, forKey: .owner)
        vertices = try c.decode(Data.self, forKey: .vertices)
        indices = try c.decode(Data.self, forKey: .indices)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        scannedAt = try c.decodeIfPresent(Date.self, forKey: .scannedAt) ?? .distantPast
    }

    var geometry: ScanGeometry { ScanGeometry(vertices: vertices, indices: indices) }
}

/// This headset's scan as other headsets know it: its identity, the site it belongs to, and where
/// its scan frame sits in that site's frame. Saved as `scans/site/scan.json`, so Clear scan (which
/// deletes the directory) also starts a new scan and a new site.
struct ScanIdentity: Codable, Equatable {
    var scanID: UUID
    var site: SiteInfo
    /// Column-major 4×4; identity for the headset that started the site.
    var siteFromScan: [Float]
    var joinedAt: Date
    var quality: AlignmentQuality
    /// Revision the next cell write gets.
    var nextRevision: Int
    /// Revision of the last published `OriginRecord`.
    var originRevision: Int

    /// A new scan starting its own site.
    static func fresh(now: Date = Date()) -> ScanIdentity {
        ScanIdentity(
            scanID: UUID(), site: SiteInfo(siteID: UUID(), created: now),
            siteFromScan: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
            joinedAt: now, quality: .root, nextRevision: 1, originRevision: 0)
    }
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
                  var record = try? decoder.decode(ScanCellRecord.self, from: data) else { continue }
            if record.scannedAt == .distantPast {
                record.scannedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            }
            loaded.cells[key] = record
        }
        return loaded
    }

    /// This headset's scan identity; a scan saved before sharing existed gets a fresh one, which
    /// starts its own site.
    static func loadIdentity() -> ScanIdentity {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        if let identity = (try? Data(contentsOf: identityFile)).flatMap({ try? decoder.decode(ScanIdentity.self, from: $0) }) {
            return identity
        }
        let identity = ScanIdentity.fresh()
        saveIdentity(identity)
        return identity
    }

    static func saveIdentity(_ identity: ScanIdentity) {
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try? encoder.encode(identity).write(to: identityFile, options: .atomic)
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
        for dir in dirs where dir.lastPathComponent != "site" && dir.lastPathComponent != "peers"
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

    private static var identityFile: URL { directory.appending(path: "scan.json") }
}
