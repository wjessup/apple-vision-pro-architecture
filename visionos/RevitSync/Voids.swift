import Foundation

struct VoidMark: Codable, Identifiable, Equatable {
    var id = UUID()
    var outline: [SIMD3<Float>]
    var top: Float

    var void: Footprint.Void { Footprint.Void(outline: outline, top: top) }
}

extension Array where Element == VoidMark {
    private static func key(_ project: String) -> String { "voids.\(project)" }

    static func load(project: String) -> [VoidMark] {
        guard let data = UserDefaults.standard.data(forKey: key(project)) else { return [] }
        return (try? JSONDecoder().decode([VoidMark].self, from: data)) ?? []
    }

    func save(project: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key(project))
    }
}
