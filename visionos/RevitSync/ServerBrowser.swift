import Foundation
import Network

struct DiscoveredServer: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
}

@MainActor
final class ServerBrowser {
    private var browser: NWBrowser?
    private var resolving: [String: NWConnection] = [:]
    private var found: [String: DiscoveredServer] = [:]
    private var onChange: (([DiscoveredServer]) -> Void)?

    func start(onChange: @escaping ([DiscoveredServer]) -> Void) {
        self.onChange = onChange
        let browser = NWBrowser(for: .bonjour(type: "_revitsync._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.handle(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolving.values.forEach { $0.cancel() }
        resolving.removeAll()
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        var live: Set<String> = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            live.insert(name)
            if found[name] == nil, resolving[name] == nil {
                resolve(name: name, endpoint: result.endpoint)
            }
        }
        for name in found.keys where !live.contains(name) {
            found[name] = nil
        }
        onChange?(found.values.sorted { $0.name < $1.name })
    }

    private func resolve(name: String, endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        resolving[name] = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint,
                       let url = Self.url(host: host, port: port) {
                        self.found[name] = DiscoveredServer(id: name, name: name, url: url)
                        self.onChange?(self.found.values.sorted { $0.name < $1.name })
                    }
                    connection.cancel()
                    self.resolving[name] = nil
                case .failed, .cancelled:
                    self.resolving[name] = nil
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private static func url(host: NWEndpoint.Host, port: NWEndpoint.Port) -> URL? {
        switch host {
        case .ipv4(let address):
            return URL(string: "http://\(address):\(port)")
        case .ipv6(let address):
            return URL(string: "http://[\(address)]:\(port)")
        case .name(let name, _):
            return URL(string: "http://\(name):\(port)")
        @unknown default:
            return nil
        }
    }
}
