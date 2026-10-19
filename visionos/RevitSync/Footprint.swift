import Foundation

enum Footprint {
    static let cornerNames = ["NW", "NE", "SE", "SW"]

    /// Plan-view (x, z) convex hull, counter-clockwise when viewed from +Y. Each vertex's y is the lowest y
    /// among input points within 1 mm of it in plan, so a vertical edge reports its bottom.
    static func hull(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        let sorted = points.sorted { $0.x < $1.x || ($0.x == $1.x && $0.z < $1.z) }
        func cross(_ o: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            (a.x - o.x) * (b.z - o.z) - (a.z - o.z) * (b.x - o.x)
        }
        var chain: [SIMD3<Float>] = []
        if sorted.count < 3 {
            for p in sorted where chain.last.map({ $0.x != p.x || $0.z != p.z }) ?? true {
                chain.append(p)
            }
        } else {
            chain.reserveCapacity(64)
            for p in sorted {
                while chain.count >= 2 && cross(chain[chain.count - 2], chain[chain.count - 1], p) <= 0 {
                    chain.removeLast()
                }
                chain.append(p)
            }
            let lowerCount = chain.count + 1
            for p in sorted.reversed().dropFirst() {
                while chain.count >= lowerCount && cross(chain[chain.count - 2], chain[chain.count - 1], p) <= 0 {
                    chain.removeLast()
                }
                chain.append(p)
            }
            chain.removeLast()
            chain.reverse()
        }

        let tolerance: Float = 0.001
        return chain.map { v in
            var lo = 0
            var hi = sorted.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if sorted[mid].x < v.x - tolerance { lo = mid + 1 } else { hi = mid }
            }
            var y = v.y
            var i = lo
            while i < sorted.count && sorted[i].x <= v.x + tolerance {
                let p = sorted[i]
                if abs(p.z - v.z) <= tolerance && p.y < y { y = p.y }
                i += 1
            }
            return SIMD3(v.x, y, v.z)
        }
    }

    /// Corners come from the ground floor alone: a basement or footing that reaches past the walls
    /// would otherwise move them. Walls are long vertical triangles with no vertex mid-height, so the
    /// floor is read as the plan section 1 m above level 0, where triangles cross that plane.
    static let groundSectionHeight: Float = 1

    /// Two models are taken as the same house when every footprint corner is within a foot in plan.
    static let sameHouseTolerance: Float = 0.3048

    /// Points where the triangles cross `y = groundSectionHeight`, dropped to level 0 (y = 0).
    static func groundSection(positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        let h = groundSectionHeight
        var points: [SIMD3<Float>] = []
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            let tri = [positions[Int(indices[t])], positions[Int(indices[t + 1])], positions[Int(indices[t + 2])]]
            for i in 0..<3 {
                let p = tri[i], q = tri[(i + 1) % 3]
                if p.y == h {
                    points.append(SIMD3(p.x, 0, p.z))
                } else if (p.y - h) * (q.y - h) < 0 {
                    let f = (h - p.y) / (q.y - p.y)
                    points.append(SIMD3(p.x + (q.x - p.x) * f, 0, p.z + (q.z - p.z) * f))
                }
            }
        }
        return points
    }

    static func sameHouse(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { p, q in
            let dx = p.x - q.x, dz = p.z - q.z
            return (dx * dx + dz * dz).squareRoot() <= sameHouseTolerance
        }
    }

    /// The four hull vertices enclosing the largest area, ordered NW, NE, SE, SW (project north is −Z).
    /// nil when the plan outline has fewer than four hull vertices.
    static func corners(of points: [SIMD3<Float>]) -> [SIMD3<Float>]? {
        let h = hull(points)
        let n = h.count
        guard n >= 4 else { return nil }
        let xs = h.map { Double($0.x) }
        let zs = h.map { Double($0.z) }
        func area(_ a: Int, _ b: Int, _ c: Int) -> Double {
            let a = a % n, b = b % n, c = c % n
            return abs((xs[b] - xs[a]) * (zs[c] - zs[a]) - (zs[b] - zs[a]) * (xs[c] - xs[a]))
        }

        var best = -1.0
        var bestQuad = (0, 1, 2, 3)
        for i in 0..<n {
            var k = i + 1
            var l = i + 3
            for j in (i + 2)..<(i + n - 1) {
                if k >= j { k = j - 1 }
                while k + 1 < j && area(i, k + 1, j) >= area(i, k, j) { k += 1 }
                if l <= j { l = j + 1 }
                while l + 1 < i + n && area(j, l + 1, i) >= area(j, l, i) { l += 1 }
                let total = area(i, k, j) + area(j, l, i)
                if total > best {
                    best = total
                    bestQuad = (i, k % n, j % n, l % n)
                }
            }
        }

        var quad = [h[bestQuad.0], h[bestQuad.1], h[bestQuad.2], h[bestQuad.3]]
        var shoelace: Float = 0
        for idx in 0..<4 {
            let p = quad[idx], q = quad[(idx + 1) % 4]
            shoelace += p.x * q.z - q.x * p.z
        }
        if shoelace < 0 { quad.reverse() }
        let start = (0..<4).min { quad[$0].x + quad[$0].z < quad[$1].x + quad[$1].z }!
        return (0..<4).map { quad[(start + $0) % 4] }
    }

    /// Placement that keeps local point `a` at world point `aWorld` and swings/scales about it so local point `b`
    /// lands on `target` in plan. Yaw follows `simd_quatf(angle: yaw, axis: [0, 1, 0])`.
    static func solveTwoPoint(
        a: SIMD3<Float>, aWorld: SIMD3<Float>, b: SIMD3<Float>, target: SIMD3<Float>, scaleRange: ClosedRange<Float>
    ) -> (position: SIMD3<Float>, yaw: Float, scale: Float)? {
        let dx = b.x - a.x, dz = b.z - a.z
        let tx = target.x - aWorld.x, tz = target.z - aWorld.z
        let localLength = (dx * dx + dz * dz).squareRoot()
        let worldLength = (tx * tx + tz * tz).squareRoot()
        guard localLength >= 1e-6, worldLength >= 1e-6 else { return nil }
        var yaw = atan2(tx, tz) - atan2(dx, dz)
        if yaw > .pi { yaw -= 2 * .pi }
        if yaw <= -.pi { yaw += 2 * .pi }
        let scale = min(max(worldLength / localLength, scaleRange.lowerBound), scaleRange.upperBound)
        let position = aWorld - world(a, position: .zero, yaw: yaw, scale: scale)
        return (position, yaw, scale)
    }

    /// World position of local point `p` under a placement.
    static func world(_ p: SIMD3<Float>, position: SIMD3<Float>, yaw: Float, scale: Float) -> SIMD3<Float> {
        let c = cos(yaw), s = sin(yaw)
        let q = p * scale
        return position + SIMD3(q.x * c + q.z * s, q.y, -q.x * s + q.z * c)
    }

    /// A model volume (pool, car ramp) inside which scanned real surfaces must not occlude.
    /// Nested so it doesn't shadow `Swift.Void` across the module.
    struct Void {
        var outline: [SIMD3<Float>]
        var top: Float

        /// The 0.1 m above `top` is ARKit's vertical placement error for a flat scanned surface: a pool whose
        /// coping sits exactly at grade would otherwise keep about half of the lawn triangles over it. There is
        /// no lower bound because nothing real is scanned beneath a pool floor or a ramp surface.
        var ceiling: Float { top + 0.1 }

        func contains(_ p: SIMD3<Float>) -> Bool {
            guard p.y <= ceiling else { return false }
            var inside = false
            var j = outline.count - 1
            for i in outline.indices {
                let a = outline[i], b = outline[j]
                if (a.z > p.z) != (b.z > p.z), p.x < (b.x - a.x) * (p.z - a.z) / (b.z - a.z) + a.x {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }
    }
}
