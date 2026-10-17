import Foundation

struct ProjectSummary: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let revision: Int
    let updatedAt: String
}

struct ProjectList: Codable {
    let projects: [ProjectSummary]
}

struct Partition: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let file: String
    let sha256: String
    let bytes: Int

    var fileExtension: String {
        (file as NSString).pathExtension
    }
}

struct Manifest: Codable {
    let project: String
    let name: String
    let revision: Int
    let partitions: [Partition]
}

enum ServerEvent: Decodable {
    case hello(revisions: [String: Int])
    case sceneUpdated(project: String, revision: Int, changed: [String], removed: [String])
    case unknown(String)

    private enum CodingKeys: String, CodingKey {
        case event, revisions, project, revision, changed, removed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let event = try c.decode(String.self, forKey: .event)
        switch event {
        case "hello":
            self = .hello(revisions: try c.decode([String: Int].self, forKey: .revisions))
        case "scene.updated":
            self = .sceneUpdated(
                project: try c.decode(String.self, forKey: .project),
                revision: try c.decode(Int.self, forKey: .revision),
                changed: try c.decode([String].self, forKey: .changed),
                removed: try c.decode([String].self, forKey: .removed))
        default:
            self = .unknown(event)
        }
    }
}
