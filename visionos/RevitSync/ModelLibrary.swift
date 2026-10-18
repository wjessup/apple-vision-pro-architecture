import Foundation

/// Synced projects kept on the device. A project's `manifest.json` is written only after every
/// asset it references has been downloaded and loaded, so a saved manifest always opens offline.
enum ModelLibrary {
    static let root: URL = {
        var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "models", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    static func assetURL(project: String, partition: Partition) -> URL {
        directory(project).appending(path: fileName(partition))
    }

    static func manifests() -> [String: Manifest] {
        let projects = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var result: [String: Manifest] = [:]
        for dir in projects {
            guard let data = try? Data(contentsOf: dir.appending(path: "manifest.json")),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { continue }
            result[manifest.project] = manifest
        }
        return result
    }

    static func save(_ manifest: Manifest) throws {
        let dir = directory(manifest.project)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: dir.appending(path: "manifest.json"), options: .atomic)
        let keep = Set(manifest.partitions.map(fileName)).union(["manifest.json"])
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) where !keep.contains(file) {
            try? FileManager.default.removeItem(at: dir.appending(path: file))
        }
    }

    private static func directory(_ project: String) -> URL {
        root.appending(path: project, directoryHint: .isDirectory)
    }

    private static func fileName(_ partition: Partition) -> String {
        "\(partition.sha256).\(partition.fileExtension)"
    }
}
