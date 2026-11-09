import Foundation

/// A rigid correction about the vertical axis: rotate by `yaw` around `pivot`, then shift by
/// `translation`. Gravity is known to the headset, so remembered scan only drifts in heading and
/// position, never in pitch or roll.
struct ScanAlignment: Equatable {
    var yaw: Float = 0
    var translation: SIMD3<Float> = .zero
    var pivot: SIMD3<Float> = .zero
    /// Remembered points that found a live surface within the final radius after alignment.
    var inliers = 0
    var inlierFraction: Float = 0

    static let maxShift: Float = 0.5
    static let maxYaw: Float = 5 * .pi / 180

    func apply(_ p: SIMD3<Float>) -> SIMD3<Float> {
        ScanAlign.rotated(p - pivot, by: yaw) + pivot + translation
    }

    /// The remembered geometry matches what the headset sees now once moved by a small amount, so
    /// the difference is tracking drift rather than a real change on the property.
    var isDrift: Bool {
        inliers >= 200 && inlierFraction >= 0.6 && length3(translation) <= Self.maxShift && abs(yaw) <= Self.maxYaw
    }

    /// Column-major 4×4 matrix, the packing `ScanAnchorRecord.scanFromAnchor` uses.
    var columns: [Float] {
        let c = cos(yaw), s = sin(yaw)
        let shift = pivot + translation - ScanAlign.rotated(pivot, by: yaw)
        return [c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, shift.x, shift.y, shift.z, 1]
    }
}

/// Point-to-plane registration of remembered scan points onto live scan triangles, restricted to
/// yaw plus translation. Foundation-only so it can be checked off the headset.
enum ScanAlign {
    static let maxSamples = 1500
    static let radii: [Float] = [0.3, 0.25, 0.2, 0.15, 0.1, 0.1]
    /// A remembered point counts as matched within this distance of a live surface's plane.
    static let inlierPlaneDistance: Float = 0.05

    /// Live surface samples (triangle centroids with unit normals) hashed into 10 cm voxels.
    struct Target {
        static let voxel: Float = 0.1
        private(set) var points: [SIMD3<Float>] = []
        private(set) var normals: [SIMD3<Float>] = []
        private var grid: [SIMD3<Int32>: [Int32]] = [:]

        init(positions: [SIMD3<Float>], indices: [UInt32]) {
            for t in stride(from: 0, to: indices.count - 2, by: 3) {
                let a = positions[Int(indices[t])], b = positions[Int(indices[t + 1])], c = positions[Int(indices[t + 2])]
                let cross = cross3(b - a, c - a)
                let length = length3(cross)
                guard length > 1e-8 else { continue }
                let centre = (a + b + c) / 3
                grid[Self.cell(centre), default: []].append(Int32(points.count))
                points.append(centre)
                normals.append(cross / length)
            }
        }

        var isEmpty: Bool { points.isEmpty }

        func nearest(to p: SIMD3<Float>, within radius: Float) -> Int? {
            let reach = Int32((radius / Self.voxel).rounded(.up))
            let centre = Self.cell(p)
            var best: Int?
            var bestDistance = radius * radius
            for dx in -reach...reach {
                for dy in -reach...reach {
                    for dz in -reach...reach {
                        guard let bucket = grid[centre &+ SIMD3(dx, dy, dz)] else { continue }
                        for i in bucket {
                            let d = points[Int(i)] - p
                            let distance = dot3(d, d)
                            if distance <= bestDistance {
                                bestDistance = distance
                                best = Int(i)
                            }
                        }
                    }
                }
            }
            return best
        }

        private static func cell(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            let c = (p / voxel).rounded(.down)
            return SIMD3(Int32(c.x), Int32(c.y), Int32(c.z))
        }
    }

    /// Finds the yaw and translation that move `source` (remembered points) onto `target` (live
    /// surfaces). Correspondences start within 30 cm and tighten to 10 cm; the damped normal
    /// equations keep any axis the overlap cannot constrain (floor-only: everything but height)
    /// near zero instead of letting it slide.
    static func register(source all: [SIMD3<Float>], target: Target) -> ScanAlignment {
        let step = max(1, all.count / maxSamples)
        let source = stride(from: 0, to: all.count, by: step).map { all[$0] }
        guard !source.isEmpty, !target.isEmpty else { return ScanAlignment() }
        var result = ScanAlignment(pivot: source.reduce(.zero, +) / Float(source.count))

        for radius in radii {
            var jtj = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
            var jtr = [Double](repeating: 0, count: 4)
            var count = 0
            for p in source {
                let moved = result.apply(p)
                guard let i = target.nearest(to: moved, within: radius) else { continue }
                let n = target.normals[i]
                let d = moved - result.pivot
                let row = [Double(n.x * d.z - n.z * d.x), Double(n.x), Double(n.y), Double(n.z)]
                let residual = Double(dot3(n, moved - target.points[i]))
                for r in 0..<4 {
                    jtr[r] += row[r] * residual
                    for c in 0..<4 { jtj[r][c] += row[r] * row[c] }
                }
                count += 1
            }
            guard count >= 3 else { break }
            let damping = 1e-3 * Double(count)
            for r in 0..<4 { jtj[r][r] += damping }
            guard let delta = solve(jtj, jtr.map { -$0 }) else { break }
            let dYaw = Float(delta[0])
            result.translation = rotated(result.translation, by: dYaw) + SIMD3(Float(delta[1]), Float(delta[2]), Float(delta[3]))
            result.yaw += dYaw
        }

        let finalRadius = radii.last!
        result.inliers = source.reduce(0) { total, p in
            let moved = result.apply(p)
            guard let i = target.nearest(to: moved, within: finalRadius),
                  abs(dot3(target.normals[i], moved - target.points[i])) <= inlierPlaneDistance else { return total }
            return total + 1
        }
        // Scaled back to the full set so the count threshold does not depend on the sampling step.
        result.inliers *= step
        result.inlierFraction = Float(result.inliers) / Float(source.count * step)
        return result
    }

    static func rotated(_ p: SIMD3<Float>, by yaw: Float) -> SIMD3<Float> {
        let c = cos(yaw), s = sin(yaw)
        return SIMD3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z)
    }

    /// Gaussian elimination with partial pivoting on a 4×4 system.
    private static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        var m = a
        var v = b
        let n = v.count
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[pivot][col]) > 1e-12 else { return nil }
            m.swapAt(col, pivot)
            v.swapAt(col, pivot)
            for row in (col + 1)..<n {
                let f = m[row][col] / m[col][col]
                for k in col..<n { m[row][k] -= f * m[col][k] }
                v[row] -= f * v[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = v[row]
            for k in (row + 1)..<n { sum -= m[row][k] * x[k] }
            x[row] = sum / m[row][row]
        }
        return x
    }

    private static func cross3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
}

private func dot3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { (a * b).sum() }
private func length3(_ a: SIMD3<Float>) -> Float { dot3(a, a).squareRoot() }
