import Foundation

struct Measurement: Codable, Identifiable, Equatable {
    var id = UUID()
    var a: SIMD3<Float>
    var b: SIMD3<Float>

    var meters: Float {
        let d = b - a
        return (d * d).sum().squareRoot()
    }
}

func feetAndInches(meters: Float) -> String {
    let quarters = Int((Double(meters) / 0.0254 * 4).rounded())
    let feet = quarters / 48
    let inches = (quarters % 48) / 4
    let fraction = ["", "¼", "½", "¾"][quarters % 4]
    return "\(feet)' \(inches)\(fraction)\""
}

extension Array where Element == Measurement {
    private static func key(_ project: String) -> String { "measurements.\(project)" }

    static func load(project: String) -> [Measurement] {
        guard let data = UserDefaults.standard.data(forKey: key(project)) else { return [] }
        return (try? JSONDecoder().decode([Measurement].self, from: data)) ?? []
    }

    func save(project: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key(project))
    }
}
