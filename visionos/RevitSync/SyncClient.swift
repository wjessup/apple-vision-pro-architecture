import Foundation

struct SyncError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class SyncClient {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    func projects() async throws -> [ProjectSummary] {
        try await get(ProjectList.self, path: "api/projects").projects
    }

    func manifest(project: String) async throws -> Manifest {
        try await get(Manifest.self, path: "api/projects/\(project)/manifest")
    }

    func download(project: String, partition: Partition) async throws -> URL {
        let target = SyncClient.cacheURL(project: project, partition: partition)
        if FileManager.default.fileExists(atPath: target.path) {
            return target
        }
        let url = baseURL.appending(path: "api/projects/\(project)/").appending(path: partition.file)
        let (temp, response) = try await session.download(from: url)
        try Self.check(response, url: url)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    func events() -> AsyncThrowingStream<ServerEvent, Error> {
        var components = URLComponents(url: baseURL.appending(path: "api/ws"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        let task = session.webSocketTask(with: components.url!)
        return AsyncThrowingStream { continuation in
            task.resume()
            let pump = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        guard case .string(let text) = message, let data = text.data(using: .utf8) else { continue }
                        continuation.yield(try JSONDecoder().decode(ServerEvent.self, from: data))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                pump.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    static func cacheURL(project: String, partition: Partition) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "models/\(project)")
            .appending(path: "\(partition.sha256).\(partition.fileExtension)")
    }

    private func get<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        let url = baseURL.appending(path: path)
        let (data, response) = try await session.data(from: url)
        try Self.check(response, url: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func check(_ response: URLResponse, url: URL) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw SyncError(message: "HTTP \(http.statusCode) from \(url.lastPathComponent)")
        }
    }
}
