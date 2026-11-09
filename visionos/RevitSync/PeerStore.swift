import Foundation

/// Copies of other headsets' scans, kept so they show here and are passed on to headsets met later.
/// Each scan is stored as its headset sent it: an `OriginRecord` plus cells in that headset's scan
/// frame, newest revision per cell. Also holds the newest site placement and the tombstones of
/// cleared scans. Layout under `root`: `<scanID>/origin.plist`, `<scanID>/cells/<ix>_<iy>_<iz>.cell`,
/// `placement.plist`, `tombstones.json`. Foundation-only so it can be checked off the headset.
final class PeerStore {
    static var defaultRoot: URL { ScanStore.root.appending(path: "peers", directoryHint: .isDirectory) }

    let root: URL
    private(set) var origins: [UUID: OriginRecord] = [:]
    private(set) var cells: [UUID: [CellKey: PeerCell]] = [:]
    private(set) var tombstones: Set<UUID> = []
    private(set) var placement: SitePlacement?

    init(root: URL = PeerStore.defaultRoot) {
        self.root = root
        load()
    }

    /// Highest cell revision held for a scan; nil when none is held.
    func highestRevision(of scanID: UUID) -> Int? {
        cells[scanID]?.values.map(\.revision).max()
    }

    /// Highest revision held per scan, as sent in `PeerHello.have`.
    var have: [UUID: Int] {
        cells.compactMapValues { $0.values.map(\.revision).max() }
    }

    /// A scan's cells above `revision` (all of them for nil), oldest first. Sending them in this
    /// order means a receiver cut off part-way still holds a prefix of the scan's history, so its
    /// highest revision says exactly what it is missing.
    func cells(of scanID: UUID, above revision: Int?) -> [PeerCell] {
        (cells[scanID]?.values.filter { $0.revision > (revision ?? Int.min) } ?? []).sorted { $0.revision < $1.revision }
    }

    /// Keeps the record if its scan is not cleared and it is newer than the one held.
    @discardableResult
    func apply(_ origin: OriginRecord) -> Bool {
        guard !tombstones.contains(origin.scanID),
              origins[origin.scanID].map({ origin.revision > $0.revision }) ?? true else { return false }
        origins[origin.scanID] = origin
        write(origin, to: scanDirectory(origin.scanID).appending(path: "origin.plist"))
        return true
    }

    /// Keeps the cell if its scan is not cleared and it is newer than the held cell at that key.
    @discardableResult
    func apply(_ cell: PeerCell) -> Bool {
        guard !tombstones.contains(cell.scanID),
              cells[cell.scanID]?[cell.key].map({ cell.revision > $0.revision }) ?? true else { return false }
        cells[cell.scanID, default: [:]][cell.key] = cell
        write(cell, to: cellDirectory(cell.scanID).appending(path: "\(cell.key.fileName).cell"))
        return true
    }

    /// Keeps the placement if it is newer than the one held. Callers only pass placements of the
    /// site this headset is in.
    @discardableResult
    func apply(_ placement: SitePlacement) -> Bool {
        guard self.placement.map({ placement.isNewer(than: $0) }) ?? true else { return false }
        self.placement = placement
        write(placement, to: root.appending(path: "placement.plist"))
        return true
    }

    func clearPlacement() {
        placement = nil
        try? FileManager.default.removeItem(at: root.appending(path: "placement.plist"))
    }

    /// Records that a scan was cleared by its headset and deletes every copy of it. Returns false
    /// when it was already known.
    @discardableResult
    func addTombstone(_ scanID: UUID) -> Bool {
        guard tombstones.insert(scanID).inserted else { return false }
        removeScan(scanID)
        saveTombstones()
        return true
    }

    /// Clear scan: drops every copy and the placement. Tombstones stay, so cleared scans are not
    /// taken back from other headsets.
    func clear() {
        for id in Set(origins.keys).union(cells.keys) { removeScan(id) }
        clearPlacement()
    }

    // MARK: Disk

    private func removeScan(_ scanID: UUID) {
        origins[scanID] = nil
        cells[scanID] = nil
        try? FileManager.default.removeItem(at: scanDirectory(scanID))
    }

    private func load() {
        let fm = FileManager.default
        let decoder = PropertyListDecoder()
        tombstones = Set((try? Data(contentsOf: tombstoneFile)).flatMap { try? JSONDecoder().decode([UUID].self, from: $0) } ?? [])
        placement = (try? Data(contentsOf: root.appending(path: "placement.plist"))).flatMap { try? decoder.decode(SitePlacement.self, from: $0) }
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            guard let scanID = UUID(uuidString: dir.lastPathComponent) else { continue }
            if tombstones.contains(scanID) {
                try? fm.removeItem(at: dir)
                continue
            }
            if let origin = (try? Data(contentsOf: dir.appending(path: "origin.plist"))).flatMap({ try? decoder.decode(OriginRecord.self, from: $0) }) {
                origins[scanID] = origin
            }
            let files = (try? fm.contentsOfDirectory(at: cellDirectory(scanID), includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "cell" {
                guard let cell = (try? Data(contentsOf: file)).flatMap({ try? decoder.decode(PeerCell.self, from: $0) }),
                      cell.scanID == scanID else { continue }
                cells[scanID, default: [:]][cell.key] = cell
            }
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try? encoder.encode(value).write(to: url, options: .atomic)
    }

    private func saveTombstones() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(tombstones.sorted { $0.uuidString < $1.uuidString }).write(to: tombstoneFile, options: .atomic)
    }

    private var tombstoneFile: URL { root.appending(path: "tombstones.json") }

    private func scanDirectory(_ scanID: UUID) -> URL {
        root.appending(path: scanID.uuidString, directoryHint: .isDirectory)
    }

    private func cellDirectory(_ scanID: UUID) -> URL {
        scanDirectory(scanID).appending(path: "cells", directoryHint: .isDirectory)
    }
}
