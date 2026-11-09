import Foundation

/// Headset-to-headset sync over peer-to-peer Wi-Fi (`PeerLink`). Every scan travels in the scan
/// frame of the headset that made it, together with that headset's `OriginRecord`, which says
/// where that frame sits in the shared site frame. Versioning is owned by the scan's headset, so a
/// relayed copy keeps its identity and revisions. Foundation-only so it can be checked off the headset.
enum PeerProtocol {
    static let version = 1
    static let serviceType = "_revitsync-peer._tcp"
    /// TXT record key carrying the advertiser's `deviceID`.
    static let deviceIDKey = "device"
    static let maxFrame = 16 * 1024 * 1024
    /// A placement dated further ahead than this is from a headset with a wrong clock.
    static let maxClockSkew: TimeInterval = 5 * 60
}

/// How a headset's scan frame was put into the site frame, best first.
enum AlignmentQuality: String, Codable, Equatable {
    /// Started the site: its scan frame is the site frame.
    case root
    /// From a SharePlay shared world anchor, then refined by scan matching.
    case sharedAnchor
    /// Scan matching fixed height, heading and position (walls facing two ways or more).
    case scan
    /// Scan matching fixed height only; heading and position still come from the house placement.
    case heightOnly
    /// From the house placement alone.
    case house

    /// Lined up well enough to trust where things are drawn.
    var isPrecise: Bool { self == .root || self == .sharedAnchor || self == .scan }
}

struct SiteInfo: Codable, Hashable {
    var siteID: UUID
    var created: Date

    /// The older site wins: a headset in the younger one joins it. Ties go to the smaller id.
    func isOlder(than other: SiteInfo) -> Bool {
        if created != other.created { return created < other.created }
        return siteID.uuidString < other.siteID.uuidString
    }
}

/// Where one headset's scan frame sits in its site. Published by that headset only; `revision`
/// increases with every publish, so the newest copy wins wherever it is relayed.
struct OriginRecord: Codable, Equatable {
    var scanID: UUID
    var deviceID: UUID
    var name: String
    var site: SiteInfo
    /// Column-major 4×4, like `ScanAnchorRecord.scanFromAnchor`.
    var siteFromScan: [Float]
    var joinedAt: Date
    var quality: AlignmentQuality
    var revision: Int
}

/// One 1 m cell of one headset's scan, in that headset's scan frame. `revision` is unique and
/// increasing per scan; a later write of the same key carries a higher one.
struct PeerCell: Codable, Equatable {
    var scanID: UUID
    var key: CellKey
    var revision: Int
    var scannedAt: Date
    var vertices: Data
    var indices: Data

    var geometry: ScanGeometry { ScanGeometry(vertices: vertices, indices: indices) }
}

/// The house as last placed by hand at real size, in the site frame. The newest wins.
struct SitePlacement: Codable, Equatable {
    var siteID: UUID
    /// Column-major 4×4 model pose without scale (the base point on the real ground).
    var siteFromModel: [Float]
    var placedAt: Date
    var placedBy: UUID
    var placedByName: String

    func isNewer(than other: SitePlacement) -> Bool {
        if placedAt != other.placedAt { return placedAt > other.placedAt }
        return placedBy.uuidString > other.placedBy.uuidString
    }
}

struct PeerHello: Codable, Equatable {
    var version: Int
    var deviceID: UUID
    var name: String
    var site: SiteInfo
    /// This headset's own scan id.
    var scanID: UUID
    /// Highest cell revision held per scan (own and relayed copies).
    var have: [UUID: Int]
    var tombstones: [UUID]
}

/// The sender's head, in the sender's scan frame.
struct PeerPose: Codable, Equatable {
    var scanID: UUID
    var scanFromHead: [Float]
}

/// A SharePlay shared world anchor, and where it sits in the sender's site.
struct PeerSharedAnchor: Codable, Equatable {
    var anchorID: UUID
    var siteID: UUID
    var siteFromAnchor: [Float]
}

enum PeerMessage: Codable, Equatable {
    case hello(PeerHello)
    case tombstones([UUID])
    case origin(OriginRecord)
    case placement(SitePlacement)
    /// The next `count` cell messages are the catch-up after hello.
    case catchUp(count: Int)
    case cell(PeerCell)
    case pose(PeerPose)
    case sharedAnchor(PeerSharedAnchor)
}

enum PeerError: Error, Equatable {
    case frameTooLarge(Int)
}

/// Why a received frame was dropped. The connection stays open.
enum PeerRejection: Error, Equatable {
    case undecodable
    case badMatrix
    case badGeometry
    case futureDate
}

/// Every frame is a 4-byte big-endian length followed by a binary property list of one `PeerMessage`.
enum PeerFraming {
    static func encode(_ message: PeerMessage) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let body = try encoder.encode(message)
        guard body.count <= PeerProtocol.maxFrame else { throw PeerError.frameTooLarge(body.count) }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    /// Reassembles frames from a byte stream that may split or join them arbitrarily.
    struct Reader {
        private var buffer = Data()

        init() {}

        /// Every complete frame received so far, decoded and validated. Throws when a frame
        /// announces more than `PeerProtocol.maxFrame` bytes; the stream cannot be trusted after that.
        mutating func append(_ data: Data, now: Date = Date()) throws -> [Result<PeerMessage, PeerRejection>] {
            buffer.append(data)
            var out: [Result<PeerMessage, PeerRejection>] = []
            while buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(0) { Int($0) << 8 | Int($1) }
                guard length <= PeerProtocol.maxFrame else { throw PeerError.frameTooLarge(length) }
                guard buffer.count >= 4 + length else { break }
                let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
                buffer = buffer.subdata(in: buffer.startIndex + 4 + length ..< buffer.endIndex)
                out.append(Self.decode(body, now: now))
            }
            return out
        }

        private static func decode(_ body: Data, now: Date) -> Result<PeerMessage, PeerRejection> {
            guard let message = try? PropertyListDecoder().decode(PeerMessage.self, from: body) else { return .failure(.undecodable) }
            if let problem = message.problem(now: now) { return .failure(problem) }
            return .success(message)
        }
    }
}

extension PeerMessage {
    /// Checks received data before anything uses it: any nearby headset can connect, so nothing
    /// in a message is trusted.
    func problem(now: Date) -> PeerRejection? {
        switch self {
        case .hello, .tombstones, .catchUp:
            return nil
        case .origin(let record):
            return Self.isMatrix(record.siteFromScan) ? nil : .badMatrix
        case .placement(let placement):
            guard Self.isMatrix(placement.siteFromModel) else { return .badMatrix }
            return placement.placedAt.timeIntervalSince(now) > PeerProtocol.maxClockSkew ? .futureDate : nil
        case .cell(let cell):
            return Self.isGeometry(vertices: cell.vertices, indices: cell.indices) ? nil : .badGeometry
        case .pose(let pose):
            return Self.isMatrix(pose.scanFromHead) ? nil : .badMatrix
        case .sharedAnchor(let anchor):
            return Self.isMatrix(anchor.siteFromAnchor) ? nil : .badMatrix
        }
    }

    static func isMatrix(_ m: [Float]) -> Bool {
        m.count == 16 && m.allSatisfy(\.isFinite)
    }

    /// Whole float32 xyz triples, whole uint32 triangles, every index in range, every coordinate finite.
    static func isGeometry(vertices: Data, indices: Data) -> Bool {
        guard vertices.count % 12 == 0, indices.count % 12 == 0 else { return false }
        let positions = ScanGrid.positions(vertices)
        guard positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return false }
        let count = UInt32(positions.count)
        return ScanGrid.indices(indices).allSatisfy { $0 < count }
    }
}
