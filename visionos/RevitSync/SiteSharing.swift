import Foundation
import Observation
import RealityKit
import simd
import UIKit

/// One headset in the Other headsets list.
struct PeerRow: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String
    let connected: Bool
    let attention: Bool
}

/// How this headset is lined up with the others, for the Other headsets section.
struct AlignmentLine: Equatable {
    let text: String
    let precise: Bool
    let attention: Bool
}

/// Shares this headset's scan and the house placement with nearby headsets over `PeerLink`, keeps
/// their scans (`PeerStore`) shown in `ScanMesh`, and lines this headset's scan frame up with the
/// oldest site around: roughly from the house placement or exactly from a SharePlay shared anchor,
/// then refined by scan matching.
@MainActor
@Observable
final class SiteSharing: PeerLinkDelegate {
    private struct Connection {
        var deviceID: UUID?
        var hello: PeerHello?
        var remaining = 0
        var rejected = 0
        var pose: PeerPose?
        var poseAt: Date?
    }

    private struct KnownHeadset: Codable {
        var name: String
        var lastSeen: Date
    }

    let deviceID: UUID
    var name: String {
        didSet { UserDefaults.standard.set(name, forKey: "peerName") }
    }
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "shareWithNearby")
            if enabled { link.start() } else { link.stop() }
        }
    }
    var immersiveOpen = false {
        didSet {
            guard immersiveOpen != oldValue else { return }
            if immersiveOpen { startPoses() } else { poseTask?.cancel() }
        }
    }
    private(set) var linkState: PeerLinkState = .off
    private(set) var identity: ScanIdentity
    let lineUp: SharedAnchorSession
    /// Name tags over the heads of other headsets' wearers; add to the immersive content.
    let headMarkers = Entity()

    private var connections: [PeerConnectionID: Connection] = [:]
    private var nearby: Set<UUID> = []
    private var failures: [UUID: String] = [:]
    private var outdated: Set<UUID> = []
    private var known: [UUID: KnownHeadset]
    /// The site this headset should join but can't line up with yet.
    private var joinHint: SiteInfo?
    private var outOfLine: String?
    private var houseMoved: String?
    private var lostNotice: String?

    @ObservationIgnored private let scene: SceneController
    @ObservationIgnored private let link: PeerLink
    @ObservationIgnored private let store = PeerStore()
    @ObservationIgnored private var matchMode: ScanMesh.SiteMatchMode
    @ObservationIgnored private var misses = 0
    @ObservationIgnored private var lastPublished: simd_float4x4
    @ObservationIgnored private var shownScans: Set<UUID> = []
    /// Newest known placement of each other site, for joining by the house.
    @ObservationIgnored private var sitePlacements: [UUID: SitePlacement] = [:]
    @ObservationIgnored private var anchorMessages: [UUID: PeerSharedAnchor] = [:]
    @ObservationIgnored private var anchorLocations: [UUID: simd_float4x4] = [:]
    @ObservationIgnored private var handledAnchors: Set<UUID> = []
    @ObservationIgnored private var poseTask: Task<Void, Never>?
    @ObservationIgnored private var houseMovedTask: Task<Void, Never>?
    @ObservationIgnored private var lostTask: Task<Void, Never>?
    @ObservationIgnored private var headTags: [PeerConnectionID: (entity: Entity, name: String, precise: Bool)] = [:]

    private var scanMesh: ScanMesh { scene.scanMesh }

    init(scene: SceneController) {
        let defaults = UserDefaults.standard
        let deviceID: UUID
        if let saved = defaults.string(forKey: "peerDeviceID").flatMap(UUID.init(uuidString:)) {
            deviceID = saved
        } else {
            deviceID = UUID()
            defaults.set(deviceID.uuidString, forKey: "peerDeviceID")
        }
        self.deviceID = deviceID
        name = defaults.string(forKey: "peerName") ?? "Vision Pro \(deviceID.uuidString.prefix(4))"
        enabled = defaults.object(forKey: "shareWithNearby") as? Bool ?? true
        known = (defaults.data(forKey: "peerHeadsets")).flatMap { try? JSONDecoder().decode([UUID: KnownHeadset].self, from: $0) } ?? [:]
        let identity = ScanStore.loadIdentity()
        self.identity = identity
        matchMode = identity.quality == .house || identity.quality == .heightOnly ? .join : .refine
        lastPublished = ScanMesh.matrix(identity.siteFromScan)
        self.scene = scene
        link = PeerLink(deviceID: deviceID)
        lineUp = SharedAnchorSession(scene: scene)
        lineUp.sharing = self
        link.delegate = self

        scanMesh.nextCellRevision = { [weak self] in
            guard let self else { return 0 }
            defer { identity.nextRevision += 1 }
            return identity.nextRevision
        }
        scanMesh.onCellsWritten = { [weak self] written in self?.cellsWritten(written) }
        scanMesh.onSiteMatch = { [weak self] result, correction, mode in self?.siteMatched(result, correction: correction, mode: mode) }
        scene.onPlacementPublished = { [weak self] scanFromModel in self?.publishPlacement(scanFromModel) }
        scene.onScanCleared = { [weak self] in self?.scanCleared() }
        scene.onSharedAnchor = { [weak self] id, originFromAnchor in self?.sharedAnchorLocated(id, originFromAnchor: originFromAnchor) }
        updateLayers()
        updateSiteMatch()
        evaluateMembership()
        if enabled { link.start() }
    }

    // MARK: View state

    var alignmentLine: AlignmentLine {
        if let outOfLine { return AlignmentLine(text: outOfLine, precise: false, attention: true) }
        if let joinHint {
            return AlignmentLine(text: "Not lined up yet: to line up with \(headsetName(in: joinHint)), place the house at real size where it stands, or start SharePlay.", precise: false, attention: true)
        }
        switch identity.quality {
        case .root: return AlignmentLine(text: "Started this site", precise: true, attention: false)
        case .scan: return AlignmentLine(text: "Lined up by scan", precise: true, attention: false)
        case .sharedAnchor: return AlignmentLine(text: "Lined up by SharePlay anchor", precise: true, attention: false)
        case .heightOnly: return AlignmentLine(text: "Lined up by height only, position from house", precise: false, attention: false)
        case .house: return AlignmentLine(text: "Lined up by house placement only", precise: false, attention: false)
        }
    }

    var linkProblem: String? {
        switch linkState {
        case .off, .running: nil
        case .permissionDenied: "Local network access is off for Revit Sync. Turn it on in Settings → Privacy & Security → Local Network."
        case .noWiFi: "Wi-Fi is off. Turn on Wi-Fi to find other headsets (no network needed)."
        case .failed(let reason): "Can't look for other headsets: \(reason). Retrying."
        }
    }

    /// Shown on the tools panel when something needs the wearer's attention; nil otherwise.
    var toolsNotice: String? {
        if let outOfLine { return outOfLine }
        if joinHint != nil { return alignmentLine.text }
        return houseMoved ?? lostNotice
    }

    var peerRows: [PeerRow] {
        var rows: [PeerRow] = []
        var listed = Set<UUID>()
        let live = connections.sorted { displayName($0.value) < displayName($1.value) }
        for (id, connection) in live {
            let device = connection.deviceID
            if let device { listed.insert(device) }
            let status: String
            if let device, outdated.contains(device) {
                status = "Needs app update"
            } else if connection.hello == nil {
                status = "Connecting…"
            } else if connection.remaining > 0 {
                status = "Syncing \(connection.remaining) piece\(connection.remaining == 1 ? "" : "s")"
            } else {
                status = "Up to date"
            }
            let dropped = connection.rejected > 0 ? " · \(connection.rejected) message\(connection.rejected == 1 ? "" : "s") dropped" : ""
            rows.append(PeerRow(id: id.uuidString, name: displayName(connection), status: status + dropped,
                                connected: true, attention: device.map(outdated.contains) ?? false))
        }
        let others = Set(known.keys).union(nearby).subtracting(listed)
        let sorted = others.sorted { (nearby.contains($0) ? 0 : 1, known[$0]?.name ?? "") < (nearby.contains($1) ? 0 : 1, known[$1]?.name ?? "") }
        for device in sorted {
            let status: String
            var attention = true
            if outdated.contains(device) {
                status = "Needs app update"
            } else if let failure = failures[device] {
                status = "Connection failed: \(failure), retrying"
            } else if nearby.contains(device) {
                status = "Connecting…"
                attention = false
            } else if let seen = known[device]?.lastSeen {
                status = "Not nearby, last seen \(Self.lastSeenFormat.string(from: seen))"
                attention = false
            } else {
                status = "Not nearby"
                attention = false
            }
            rows.append(PeerRow(id: device.uuidString, name: known[device]?.name ?? "Headset nearby", status: status,
                                connected: false, attention: attention))
        }
        return rows
    }

    private static let lastSeenFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mmxxxxx"
        return formatter
    }()

    private func displayName(_ connection: Connection) -> String {
        connection.hello?.name ?? connection.deviceID.flatMap { known[$0]?.name } ?? "Headset nearby"
    }

    private func headsetName(in site: SiteInfo) -> String {
        if let hello = connections.values.compactMap(\.hello).first(where: { $0.site == site }) { return hello.name }
        return store.origins.values.filter { $0.site == site }.min { $0.joinedAt < $1.joinedAt }?.name ?? "another headset"
    }

    // MARK: PeerLinkDelegate

    func peerLink(_ link: PeerLink, stateChanged state: PeerLinkState) {
        linkState = state
    }

    func peerLink(_ link: PeerLink, nearby deviceIDs: Set<UUID>) {
        nearby = deviceIDs
        let now = Date()
        for device in deviceIDs where known[device] != nil { known[device]?.lastSeen = now }
        saveKnown()
    }

    func peerLink(_ link: PeerLink, connected id: PeerConnectionID, deviceID: UUID?) {
        connections[id] = Connection(deviceID: deviceID)
        if let deviceID { failures[deviceID] = nil }
        sendHello(to: id)
    }

    func peerLink(_ link: PeerLink, received message: PeerMessage, from id: PeerConnectionID) {
        guard connections[id] != nil else { return }
        switch message {
        case .hello(let hello): received(hello, from: id)
        case .tombstones(let ids): receivedTombstones(ids, from: id)
        case .origin(let origin): received(origin, from: id)
        case .placement(let placement): received(placement, from: id)
        case .catchUp(let count): connections[id]?.remaining = max(0, count)
        case .cell(let cell): received(cell, from: id)
        case .pose(let pose):
            connections[id]?.pose = pose
            connections[id]?.poseAt = Date()
        case .sharedAnchor(let anchor):
            anchorMessages[anchor.anchorID] = anchor
            matchSharedAnchors()
        }
    }

    func peerLink(_ link: PeerLink, rejected reason: PeerRejection, from id: PeerConnectionID) {
        guard var connection = connections[id] else { return }
        connection.rejected += 1
        connection.remaining = max(0, connection.remaining - 1)
        connections[id] = connection
    }

    func peerLink(_ link: PeerLink, disconnected id: PeerConnectionID, deviceID: UUID?, error: String?) {
        let connection = connections.removeValue(forKey: id)
        let device = deviceID ?? connection?.deviceID
        if let device {
            if let error { failures[device] = error }
            if known[device] != nil {
                known[device]?.lastSeen = Date()
                saveKnown()
            }
        }
        if let connection, connection.hello != nil, connection.remaining == 0 {
            showLost("Lost connection to \(displayName(connection))")
        }
        headTags.removeValue(forKey: id)?.entity.removeFromParent()
    }

    // MARK: Protocol

    private func sendHello(to id: PeerConnectionID) {
        var have = store.have
        if let own = scanMesh.ownCells.values.map(\.revision).max() { have[identity.scanID] = own }
        link.send(.hello(PeerHello(version: PeerProtocol.version, deviceID: deviceID, name: name, site: identity.site,
                                   scanID: identity.scanID, have: have, tombstones: Array(store.tombstones))), to: id)
    }

    private func received(_ hello: PeerHello, from id: PeerConnectionID) {
        known[hello.deviceID] = KnownHeadset(name: hello.name, lastSeen: Date())
        saveKnown()
        failures[hello.deviceID] = nil
        connections[id]?.deviceID = hello.deviceID
        guard hello.version == PeerProtocol.version else {
            outdated.insert(hello.deviceID)
            link.close(id)
            return
        }
        outdated.remove(hello.deviceID)
        connections[id]?.hello = hello
        connections[id]?.remaining = 0

        link.send(.tombstones(Array(store.tombstones)), to: id)
        link.send(.origin(ownOrigin), to: id)
        for origin in store.origins.values { link.send(.origin(origin), to: id) }
        if let placement = store.placement, placement.siteID == identity.site.siteID {
            link.send(.placement(placement), to: id)
        }
        let ownAbove = hello.have[identity.scanID] ?? Int.min
        var cells = scanMesh.ownCells
            .filter { $0.value.revision > ownAbove }
            .sorted { $0.value.revision < $1.value.revision }
            .map { PeerCell(scanID: identity.scanID, key: $0.key, revision: $0.value.revision, scannedAt: $0.value.scannedAt,
                            vertices: $0.value.vertices, indices: $0.value.indices) }
        let skipped = Set(hello.tombstones).union([hello.scanID])
        for scanID in store.cells.keys where !skipped.contains(scanID) {
            cells += store.cells(of: scanID, above: hello.have[scanID])
        }
        link.send(.catchUp(count: cells.count), to: id)
        for cell in cells { link.send(.cell(cell), to: id) }
        evaluateMembership()
    }

    private func receivedTombstones(_ ids: [UUID], from id: PeerConnectionID) {
        let accepted = ids.filter { $0 != identity.scanID && store.addTombstone($0) }
        guard !accepted.isEmpty else { return }
        for scanID in accepted {
            scanMesh.removePeerScan(scanID)
            shownScans.remove(scanID)
        }
        forward(.tombstones(accepted), except: id)
        updateSiteMatch()
    }

    private func received(_ origin: OriginRecord, from id: PeerConnectionID) {
        guard origin.scanID != identity.scanID, store.apply(origin) else { return }
        updateLayer(origin.scanID)
        forward(.origin(origin), except: id)
        evaluateMembership()
        updateSiteMatch()
    }

    private func received(_ placement: SitePlacement, from id: PeerConnectionID) {
        if placement.siteID == identity.site.siteID {
            guard store.apply(placement) else { return }
            adopt(placement)
            if placement.placedBy != deviceID { showHouseMoved(placement.placedByName) }
            forward(.placement(placement), except: id)
        } else if sitePlacements[placement.siteID].map({ placement.isNewer(than: $0) }) ?? true {
            sitePlacements[placement.siteID] = placement
        }
        evaluateMembership()
    }

    private func received(_ cell: PeerCell, from id: PeerConnectionID) {
        connections[id]?.remaining = max(0, (connections[id]?.remaining ?? 0) - 1)
        guard cell.scanID != identity.scanID, store.apply(cell) else { return }
        if shownScans.contains(cell.scanID) {
            scanMesh.updatePeerCell(cell)
        } else {
            showScan(cell.scanID)
            updateSiteMatch()
        }
        forward(.cell(cell), except: id)
    }

    private func cellsWritten(_ written: [(key: CellKey, record: ScanCellRecord)]) {
        ScanStore.saveIdentity(identity)
        let ready = helloed
        guard !ready.isEmpty else { return }
        for (key, record) in written {
            let cell = PeerCell(scanID: identity.scanID, key: key, revision: record.revision, scannedAt: record.scannedAt,
                                vertices: record.vertices, indices: record.indices)
            for id in ready { link.send(.cell(cell), to: id) }
        }
    }

    private var helloed: [PeerConnectionID] {
        connections.filter { $0.value.hello != nil }.map(\.key)
    }

    private func sendAll(_ message: PeerMessage) {
        for id in helloed { link.send(message, to: id) }
    }

    private func forward(_ message: PeerMessage, except source: PeerConnectionID) {
        for id in helloed where id != source { link.send(message, to: id) }
    }

    private var ownOrigin: OriginRecord {
        OriginRecord(scanID: identity.scanID, deviceID: deviceID, name: name, site: identity.site,
                     siteFromScan: identity.siteFromScan, joinedAt: identity.joinedAt, quality: identity.quality,
                     revision: identity.originRevision)
    }

    private func saveKnown() {
        UserDefaults.standard.set(try? JSONEncoder().encode(known), forKey: "peerHeadsets")
    }

    // MARK: Layers

    private func layer(_ scanID: UUID) -> (myScanFromPeerScan: simd_float4x4?, reference: Bool) {
        guard let origin = store.origins[scanID], origin.site == identity.site else { return (nil, false) }
        return (siteFromScan.inverse * ScanMesh.matrix(origin.siteFromScan), origin.joinedAt < identity.joinedAt)
    }

    private func showScan(_ scanID: UUID) {
        let l = layer(scanID)
        scanMesh.setPeerScan(scanID, myScanFromPeerScan: l.myScanFromPeerScan, reference: l.reference,
                             cells: store.cells[scanID].map { Array($0.values) } ?? [])
        shownScans.insert(scanID)
    }

    private func updateLayer(_ scanID: UUID) {
        if shownScans.contains(scanID) {
            let l = layer(scanID)
            scanMesh.setPeerPlacement(scanID, myScanFromPeerScan: l.myScanFromPeerScan, reference: l.reference)
        } else if store.cells[scanID]?.isEmpty == false {
            showScan(scanID)
        }
    }

    private func updateLayers() {
        for scanID in Set(store.cells.keys).union(shownScans) { updateLayer(scanID) }
    }

    private var siteFromScan: simd_float4x4 { ScanMesh.matrix(identity.siteFromScan) }

    private var references: [OriginRecord] {
        store.origins.values
            .filter { $0.site == identity.site && $0.joinedAt < identity.joinedAt && store.cells[$0.scanID]?.isEmpty == false }
            .sorted { $0.joinedAt < $1.joinedAt }
    }

    private func updateSiteMatch() {
        let mode: ScanMesh.SiteMatchMode? = identity.quality == .root || references.isEmpty ? nil : matchMode
        if scanMesh.siteMatch != mode { scanMesh.siteMatch = mode }
    }

    // MARK: Membership

    private func evaluateMembership() {
        let candidates = connections.values.compactMap(\.hello?.site) + store.origins.values.map(\.site)
        guard let oldest = candidates.min(by: { $0.isOlder(than: $1) }), oldest.isOlder(than: identity.site) else {
            joinHint = nil
            return
        }
        if let siteFromScan = anchorSiteFromScan(siteID: oldest.siteID) {
            matchMode = .refine
            join(oldest, siteFromScan: siteFromScan, quality: .sharedAnchor)
        } else if scene.atRealSize, !scene.isSearching, let scanFromModel = scene.placement.scanFromModel,
                  let placement = sitePlacements[oldest.siteID] {
            matchMode = .join
            join(oldest, siteFromScan: ScanMesh.matrix(placement.siteFromModel) * ScanMesh.matrix(scanFromModel).inverse, quality: .house)
        } else {
            joinHint = oldest
        }
    }

    private func join(_ site: SiteInfo, siteFromScan: simd_float4x4, quality: AlignmentQuality) {
        identity.site = site
        identity.siteFromScan = ScanMesh.columns(siteFromScan)
        identity.joinedAt = Date()
        identity.quality = quality
        identity.originRevision += 1
        ScanStore.saveIdentity(identity)
        lastPublished = siteFromScan
        joinHint = nil
        outOfLine = nil
        misses = 0
        sendAll(.origin(ownOrigin))
        store.clearPlacement()
        if let placement = sitePlacements[site.siteID] {
            store.apply(placement)
            adopt(placement)
            sendAll(.placement(placement))
        } else if let scanFromModel = scene.placement.scanFromModel {
            publishPlacement(ScanMesh.matrix(scanFromModel), evaluate: false)
        }
        updateLayers()
        updateSiteMatch()
    }

    // MARK: Placement

    private func publishPlacement(_ scanFromModel: simd_float4x4) {
        publishPlacement(scanFromModel, evaluate: true)
    }

    private func publishPlacement(_ scanFromModel: simd_float4x4, evaluate: Bool) {
        let placement = SitePlacement(siteID: identity.site.siteID, siteFromModel: ScanMesh.columns(siteFromScan * scanFromModel),
                                      placedAt: Date(), placedBy: deviceID, placedByName: name)
        store.apply(placement)
        sendAll(.placement(placement))
        if evaluate { evaluateMembership() }
    }

    private func adopt(_ placement: SitePlacement) {
        scene.adoptSharedPlacement(scanFromModel: siteFromScan.inverse * ScanMesh.matrix(placement.siteFromModel))
    }

    // MARK: Alignment

    private func siteMatched(_ result: ScanAlignment, correction: simd_float4x4, mode: ScanMesh.SiteMatchMode) {
        guard identity.quality != .root else { return }
        switch mode {
        case .join:
            guard result.isJoinMatch else { return }
            if result.horizontallyConstrained {
                matchMode = .refine
                correct(by: correction, quality: .scan)
            } else {
                correct(by: Self.heightOnly(correction), quality: .heightOnly)
            }
            outOfLine = nil
            misses = 0
        case .refine:
            if result.isDrift {
                correct(by: result.horizontallyConstrained ? correction : Self.heightOnly(correction), quality: identity.quality)
                misses = 0
                outOfLine = nil
            } else if result.inliers >= 200, simd_length(result.translation) > 0.10 {
                misses += 1
                if misses >= 3 {
                    let centimetres = Int((simd_length(result.translation) * 100).rounded())
                    outOfLine = "Out of line with \(references.first?.name ?? "another headset") by about \(centimetres) cm, re-matching"
                    matchMode = .join
                    misses = 0
                }
            }
        }
        updateSiteMatch()
    }

    private static func heightOnly(_ correction: simd_float4x4) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3.y = correction.columns.3.y
        return m
    }

    private func correct(by correction: simd_float4x4, quality: AlignmentQuality) {
        setSiteFromScan(siteFromScan * correction.inverse, quality: quality)
    }

    /// Saves a new pose in the site; publishes it when it moved noticeably or the quality changed,
    /// then moves the other scans and the house to match.
    private func setSiteFromScan(_ m: simd_float4x4, quality: AlignmentQuality) {
        let qualityChanged = identity.quality != quality
        identity.siteFromScan = ScanMesh.columns(m)
        identity.quality = quality
        if qualityChanged || Self.moved(from: lastPublished, to: m) {
            identity.originRevision += 1
            lastPublished = m
            ScanStore.saveIdentity(identity)
            sendAll(.origin(ownOrigin))
        } else {
            ScanStore.saveIdentity(identity)
        }
        updateLayers()
        if let placement = store.placement, placement.siteID == identity.site.siteID { adopt(placement) }
    }

    private static func moved(from a: simd_float4x4, to b: simd_float4x4) -> Bool {
        let shift = simd_length(SIMD3(b.columns.3.x - a.columns.3.x, b.columns.3.y - a.columns.3.y, b.columns.3.z - a.columns.3.z))
        let angle = simd_quatf(a.inverse * b).angle
        return shift > 0.01 || min(angle, 2 * .pi - angle) > 0.2 * .pi / 180
    }

    // MARK: Clear scan

    private func scanCleared() {
        let old = identity.scanID
        store.addTombstone(old)
        store.clear()
        scanMesh.removeAllPeerScans()
        shownScans = []
        identity = .fresh()
        ScanStore.saveIdentity(identity)
        lastPublished = siteFromScan
        matchMode = .refine
        misses = 0
        outOfLine = nil
        handledAnchors = []
        for id in connections.keys {
            link.send(.tombstones([old]), to: id)
            sendHello(to: id)
        }
        sendAll(.origin(ownOrigin))
        updateSiteMatch()
        evaluateMembership()
    }

    // MARK: Shared anchor

    /// This headset makes the SharePlay shared anchor: its site is the oldest among connected
    /// headsets and, within it, it joined first.
    var shouldCreateSharedAnchor: Bool {
        let peers = connections.values.compactMap(\.hello)
        guard !peers.isEmpty else { return false }
        return peers.allSatisfy { peer in
            if peer.site != identity.site { return identity.site.isOlder(than: peer.site) }
            guard let joined = store.origins[peer.scanID]?.joinedAt, joined != identity.joinedAt else {
                return deviceID.uuidString < peer.deviceID.uuidString
            }
            return identity.joinedAt < joined
        }
    }

    /// Tells connected headsets where a shared anchor this headset made sits in its site.
    func publishSharedAnchor(id: UUID, originFromAnchor: simd_float4x4) {
        guard let originFromScan = scanMesh.originFromScan(near: Self.translation(originFromAnchor)) else { return }
        handledAnchors.insert(id)
        let siteFromAnchor = siteFromScan * originFromScan.inverse * originFromAnchor
        sendAll(.sharedAnchor(PeerSharedAnchor(anchorID: id, siteID: identity.site.siteID, siteFromAnchor: ScanMesh.columns(siteFromAnchor))))
    }

    private func sharedAnchorLocated(_ id: UUID, originFromAnchor: simd_float4x4) {
        anchorLocations[id] = originFromAnchor
        if anchorMessages[id] != nil { matchSharedAnchors() }
    }

    private func matchSharedAnchors() {
        for (id, message) in anchorMessages where message.siteID == identity.site.siteID && !handledAnchors.contains(id) {
            guard identity.quality != .root, let siteFromScan = anchorSiteFromScan(id) else { continue }
            handledAnchors.insert(id)
            matchMode = .refine
            outOfLine = nil
            misses = 0
            setSiteFromScan(siteFromScan, quality: .sharedAnchor)
            updateSiteMatch()
        }
        evaluateMembership()
    }

    private func anchorSiteFromScan(siteID: UUID) -> simd_float4x4? {
        for (id, message) in anchorMessages where message.siteID == siteID && !handledAnchors.contains(id) {
            if let siteFromScan = anchorSiteFromScan(id) {
                handledAnchors.insert(id)
                return siteFromScan
            }
        }
        return nil
    }

    private func anchorSiteFromScan(_ id: UUID) -> simd_float4x4? {
        guard let message = anchorMessages[id], let originFromAnchor = anchorLocations[id],
              let originFromScan = scanMesh.originFromScan(near: Self.translation(originFromAnchor)) else { return nil }
        return ScanMesh.matrix(message.siteFromAnchor) * originFromAnchor.inverse * originFromScan
    }

    private static func translation(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    // MARK: Notices

    private func showHouseMoved(_ by: String) {
        houseMoved = "House moved by \(by)"
        houseMovedTask?.cancel()
        houseMovedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.houseMoved = nil
        }
    }

    private func showLost(_ text: String) {
        lostNotice = text
        lostTask?.cancel()
        lostTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.lostNotice = nil
        }
    }

    // MARK: Poses and head markers

    private func startPoses() {
        poseTask?.cancel()
        poseTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sendPose()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func sendPose() {
        guard let scanFromHead = scene.scanFromHead() else { return }
        sendAll(.pose(PeerPose(scanID: identity.scanID, scanFromHead: ScanMesh.columns(scanFromHead))))
    }

    private static let tagFont = UIFont.systemFont(ofSize: 0.06, weight: .semibold)

    /// Moves a name tag over each connected wearer whose pose is recent and who is in this site.
    /// Called every frame.
    func updateHeadMarkers() {
        let now = Date()
        var live = Set<PeerConnectionID>()
        for (id, connection) in connections {
            guard let pose = connection.pose, let at = connection.poseAt, now.timeIntervalSince(at) < 3,
                  let hello = connection.hello, let origin = store.origins[hello.scanID], origin.site == identity.site else { continue }
            let p = siteFromScan.inverse * ScanMesh.matrix(origin.siteFromScan) * ScanMesh.matrix(pose.scanFromHead)
            guard let originFromScan = scanMesh.originFromScan(nearScan: Self.translation(p)) else { continue }
            live.insert(id)
            let precise = origin.quality.isPrecise
            if headTags[id].map({ $0.name != hello.name || $0.precise != precise }) ?? true {
                headTags[id]?.entity.removeFromParent()
                let tag = Self.headTag(name: hello.name, precise: precise)
                headMarkers.addChild(tag)
                headTags[id] = (entity: tag, name: hello.name, precise: precise)
            }
            headTags[id]?.entity.position = Self.translation(originFromScan * p) + SIMD3(0, 0.25, 0)
        }
        for (id, tag) in headTags where !live.contains(id) {
            tag.entity.removeFromParent()
            headTags[id] = nil
        }
    }

    private static func headTag(name: String, precise: Bool) -> Entity {
        let text = ModelEntity(mesh: .generateText(name, extrusionDepth: 0.002, font: tagFont),
                               materials: [UnlitMaterial(color: .white)])
        let bounds = text.visualBounds(relativeTo: text)
        text.position.x = -bounds.center.x + 0.03
        text.position.y = -bounds.center.y
        let dot = ModelEntity(mesh: .generateSphere(radius: 0.02),
                              materials: [UnlitMaterial(color: precise ? .systemGreen : .systemOrange)])
        dot.position.x = -bounds.extents.x / 2
        let tag = Entity()
        tag.components.set(BillboardComponent())
        tag.addChild(text)
        tag.addChild(dot)
        return tag
    }
}
