import Foundation

/// Address of one cube of the scan grid, in scan-frame metres divided by `ScanGrid.cellSize`.
struct CellKey: Hashable, Codable {
    var ix: Int32
    var iy: Int32
    var iz: Int32

    var fileName: String { "\(ix)_\(iy)_\(iz)" }

    init(ix: Int32, iy: Int32, iz: Int32) {
        self.ix = ix
        self.iy = iy
        self.iz = iz
    }

    init?(fileName: String) {
        let parts = fileName.split(separator: "_").compactMap { Int32($0) }
        guard parts.count == 3 else { return nil }
        self.init(ix: parts[0], iy: parts[1], iz: parts[2])
    }

    var center: SIMD3<Float> {
        (SIMD3<Float>(Float(ix), Float(iy), Float(iz)) + 0.5) * ScanGrid.cellSize
    }
}

/// Packed triangle geometry: float32 xyz per vertex, uint32 indices three per triangle.
struct ScanGeometry: Equatable {
    var vertices = Data()
    var indices = Data()

    var isEmpty: Bool { indices.isEmpty }
}

struct ScanBox: Equatable {
    var min: SIMD3<Float>
    var max: SIMD3<Float>

    func contains(_ p: SIMD3<Float>) -> Bool {
        all(p .>= min) && all(p .<= max)
    }
}

/// Fixed 1 m cells of the scan frame. Replacement of remembered geometry happens per cell, so a
/// rescanned wall can only touch the cells it has triangles in. Matrices are 16 floats, column-major.
enum ScanGrid {
    static let cellSize: Float = 1

    static func key(_ p: SIMD3<Float>) -> CellKey {
        let c = (p / cellSize).rounded(.down)
        return CellKey(ix: Int32(c.x), iy: Int32(c.y), iz: Int32(c.z))
    }

    static func keys(of geometry: ScanGeometry, scanFromGeometry m: [Float]) -> Set<CellKey> {
        let scan = positions(geometry.vertices).map { apply(m, $0) }
        let idx = indices(geometry.indices)
        var keys = Set<CellKey>()
        for t in stride(from: 0, to: idx.count - 2, by: 3) {
            keys.insert(key(centroid(scan, idx, t)))
        }
        return keys
    }

    /// Splits triangles by centroid in the scan frame. Vertices stay in the input frame, re-indexed per cell.
    static func bin(_ geometry: ScanGeometry, scanFromGeometry m: [Float]) -> [CellKey: ScanGeometry] {
        let source = positions(geometry.vertices)
        let scan = source.map { apply(m, $0) }
        let idx = indices(geometry.indices)
        var builders: [CellKey: Builder] = [:]
        for t in stride(from: 0, to: idx.count - 2, by: 3) {
            builders[key(centroid(scan, idx, t)), default: Builder()].add(idx[t], idx[t + 1], idx[t + 2], from: source)
        }
        return builders.mapValues(\.geometry)
    }

    static func transformed(_ geometry: ScanGeometry, by m: [Float]) -> ScanGeometry {
        ScanGeometry(vertices: packed(positions(geometry.vertices).map { apply(m, $0) }), indices: geometry.indices)
    }

    static func bounds(of geometry: ScanGeometry) -> ScanBox? {
        let p = positions(geometry.vertices)
        guard let first = p.first else { return nil }
        return p.dropFirst().reduce(ScanBox(min: first, max: first)) {
            ScanBox(min: pointwiseMin($0.min, $1), max: pointwiseMax($0.max, $1))
        }
    }

    /// Keeps the old triangles whose centroid, mapped through `boxFromOld`, lies outside `box`, and
    /// appends `new`. The box is the extent of a complete rescan, so only re-observed space is replaced.
    static func merged(old: ScanGeometry, replacingInside box: ScanBox, boxFromOld m: [Float], with new: ScanGeometry) -> ScanGeometry {
        let source = positions(old.vertices)
        let idx = indices(old.indices)
        var builder = Builder()
        for t in stride(from: 0, to: idx.count - 2, by: 3) where !box.contains(apply(m, centroid(source, idx, t))) {
            builder.add(idx[t], idx[t + 1], idx[t + 2], from: source)
        }
        builder.append(new)
        return builder.geometry
    }

    private struct Builder {
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var remap: [UInt32: UInt32] = [:]

        mutating func add(_ a: UInt32, _ b: UInt32, _ c: UInt32, from source: [SIMD3<Float>]) {
            for i in [a, b, c] {
                if let n = remap[i] {
                    indices.append(n)
                } else {
                    let n = UInt32(vertices.count)
                    remap[i] = n
                    vertices.append(source[Int(i)])
                    indices.append(n)
                }
            }
        }

        mutating func append(_ geometry: ScanGeometry) {
            let offset = UInt32(vertices.count)
            vertices.append(contentsOf: ScanGrid.positions(geometry.vertices))
            indices.append(contentsOf: ScanGrid.indices(geometry.indices).map { $0 + offset })
        }

        var geometry: ScanGeometry { ScanGeometry(vertices: packed(vertices), indices: packed(indices)) }
    }

    private static func centroid(_ p: [SIMD3<Float>], _ idx: [UInt32], _ t: Int) -> SIMD3<Float> {
        (p[Int(idx[t])] + p[Int(idx[t + 1])] + p[Int(idx[t + 2])]) / 3
    }

    static func apply(_ m: [Float], _ p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
            m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
            m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
            m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14])
    }

    // MARK: Packing

    static func positions(_ data: Data) -> [SIMD3<Float>] {
        let floats = unpacked(data, as: Float.self)
        return stride(from: 0, to: floats.count - 2, by: 3).map { SIMD3(floats[$0], floats[$0 + 1], floats[$0 + 2]) }
    }

    static func indices(_ data: Data) -> [UInt32] {
        unpacked(data, as: UInt32.self)
    }

    static func packed(_ points: [SIMD3<Float>]) -> Data {
        points.flatMap { [$0.x, $0.y, $0.z] }.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func packed(_ indices: [UInt32]) -> Data {
        indices.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // Bytes decoded from a property list carry no alignment guarantee, so read them unaligned.
    private static func unpacked<T>(_ data: Data, as: T.Type) -> [T] {
        let size = MemoryLayout<T>.stride
        return data.withUnsafeBytes { bytes in
            (0..<(bytes.count / size)).map { bytes.loadUnaligned(fromByteOffset: $0 * size, as: T.self) }
        }
    }
}
