import Foundation
import Network

/// Local id of one connection to another headset.
typealias PeerConnectionID = UUID

enum PeerLinkState: Equatable {
    /// Not started, or stopped by the wearer.
    case off
    /// Advertising and browsing.
    case running
    /// Local network access was refused (Settings → Privacy & Security → Local Network).
    case permissionDenied
    /// Wi-Fi is off, so there is no peer-to-peer link.
    case noWiFi
    /// Advertising or browsing failed; retrying with backoff.
    case failed(String)
}

@MainActor
protocol PeerLinkDelegate: AnyObject {
    func peerLink(_ link: PeerLink, stateChanged state: PeerLinkState)
    /// Device ids currently advertising nearby (not including this headset).
    func peerLink(_ link: PeerLink, nearby deviceIDs: Set<UUID>)
    /// A connection is ready to send on. `deviceID` is known when this headset dialed (from the
    /// TXT record); nil for an incoming one until its hello arrives.
    func peerLink(_ link: PeerLink, connected id: PeerConnectionID, deviceID: UUID?)
    func peerLink(_ link: PeerLink, received message: PeerMessage, from id: PeerConnectionID)
    /// A frame was dropped; the connection stays open.
    func peerLink(_ link: PeerLink, rejected reason: PeerRejection, from id: PeerConnectionID)
    /// The connection ended (or a dial failed). `error` is nil for a clean close.
    func peerLink(_ link: PeerLink, disconnected id: PeerConnectionID, deviceID: UUID?, error: String?)
}

/// Finds other headsets running Revit Sync and keeps one connection to each, over peer-to-peer
/// Wi-Fi as well as any shared network: Bonjour `PeerProtocol.serviceType` advertised and browsed
/// with peer-to-peer enabled, length-prefixed `PeerFraming` frames over TCP. Of each pair, only the
/// headset with the lower device id dials, so a pair never has two connections.
@MainActor
final class PeerLink {
    weak var delegate: PeerLinkDelegate?
    let deviceID: UUID
    private(set) var state: PeerLinkState = .off

    private final class Peer {
        let connection: NWConnection
        var deviceID: UUID?
        let dialed: Bool
        var readyAt: Date?
        var reader = PeerFraming.Reader()
        var queue: [Data] = []
        var queueHead = 0
        var sending = false

        init(connection: NWConnection, deviceID: UUID?, dialed: Bool) {
            self.connection = connection
            self.deviceID = deviceID
            self.dialed = dialed
        }
    }

    private static let minBackoff: TimeInterval = 2
    private static let maxBackoff: TimeInterval = 60
    /// A connection that stayed up this long counts as a success and resets its device's backoff.
    private static let stableAfter: TimeInterval = 10
    private static let policyDenied: Int32 = -65570

    private var started = false
    private var generation = 0
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var listenerReady = false
    private var browserReady = false
    private var serviceProblem: PeerLinkState?
    private var serviceBackoff = PeerLink.minBackoff
    private var restartWork: DispatchWorkItem?
    private var pathMonitor: NWPathMonitor?
    private var wifiAvailable = true

    private var advertised: [UUID: NWEndpoint] = [:]
    private var peers: [PeerConnectionID: Peer] = [:]
    private var dialBackoff: [UUID: TimeInterval] = [:]
    private var redials: [UUID: DispatchWorkItem] = [:]

    init(deviceID: UUID) {
        self.deviceID = deviceID
    }

    /// Starts advertising and browsing. Calling it again while running changes nothing.
    func start() {
        guard !started else { return }
        started = true
        wifiAvailable = true
        serviceProblem = nil
        serviceBackoff = Self.minBackoff
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            let satisfied = path.status == .satisfied
            onMain {
                guard let self, let monitor, monitor === self.pathMonitor else { return }
                self.wifiChanged(satisfied)
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
        startServices()
        updateState()
    }

    /// Stops advertising and browsing and closes every connection.
    func stop() {
        guard started else { return }
        started = false
        restartWork?.cancel()
        restartWork = nil
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        generation += 1
        listenerReady = false
        browserReady = false
        pathMonitor?.cancel()
        pathMonitor = nil
        redials.values.forEach { $0.cancel() }
        redials.removeAll()
        dialBackoff.removeAll()
        serviceProblem = nil
        wifiAvailable = true
        let closed = peers
        peers.removeAll()
        for peer in closed.values {
            peer.connection.stateUpdateHandler = nil
            peer.connection.cancel()
        }
        let hadNearby = !advertised.isEmpty
        advertised.removeAll()
        updateState()
        for (id, peer) in closed {
            delegate?.peerLink(self, disconnected: id, deviceID: peer.deviceID, error: nil)
        }
        if hadNearby { delegate?.peerLink(self, nearby: []) }
    }

    /// Queues one message; frames go out one at a time, the next when the previous was sent.
    func send(_ message: PeerMessage, to id: PeerConnectionID) {
        guard let peer = peers[id], let frame = try? PeerFraming.encode(message) else { return }
        peer.queue.append(frame)
        pump(id)
    }

    func close(_ id: PeerConnectionID) {
        end(id, error: nil)
    }

    // MARK: Advertising and browsing

    private func startServices() {
        generation += 1
        let gen = generation
        listenerReady = false
        browserReady = false

        let listener: NWListener
        do {
            listener = try NWListener(using: Self.connectionParameters())
        } catch {
            servicesFailed(.failed("Couldn't advertise: \(error.localizedDescription)"))
            return
        }
        let txt = NWTXTRecord([PeerProtocol.deviceIDKey: deviceID.uuidString])
        listener.service = NWListener.Service(name: deviceID.uuidString, type: PeerProtocol.serviceType, txtRecord: txt)
        listener.stateUpdateHandler = { [weak self] state in
            onMain { self?.listenerChanged(state, generation: gen) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            onMain {
                guard let self, gen == self.generation else {
                    connection.cancel()
                    return
                }
                self.open(connection, deviceID: nil, dialed: false)
            }
        }

        let browserParameters = NWParameters()
        browserParameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: PeerProtocol.serviceType, domain: nil), using: browserParameters)
        browser.stateUpdateHandler = { [weak self] state in
            onMain { self?.browserChanged(state, generation: gen) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            onMain {
                guard let self, gen == self.generation else { return }
                self.resultsChanged(results)
            }
        }

        self.listener = listener
        self.browser = browser
        listener.start(queue: .main)
        browser.start(queue: .main)
    }

    private func listenerChanged(_ state: NWListener.State, generation gen: Int) {
        guard gen == generation else { return }
        switch state {
        case .ready:
            listenerReady = true
            servicesMaybeReady()
        case .waiting(let error):
            if Self.isPolicyDenied(error) {
                serviceProblem = .permissionDenied
                updateState()
            }
        case .failed(let error):
            servicesFailed(Self.isPolicyDenied(error) ? .permissionDenied : .failed("Couldn't advertise: \(Self.describe(error))"))
        default:
            break
        }
    }

    private func browserChanged(_ state: NWBrowser.State, generation gen: Int) {
        guard gen == generation else { return }
        switch state {
        case .ready:
            browserReady = true
            servicesMaybeReady()
        case .waiting(let error):
            if Self.isPolicyDenied(error) {
                serviceProblem = .permissionDenied
                updateState()
            }
        case .failed(let error):
            servicesFailed(Self.isPolicyDenied(error) ? .permissionDenied : .failed("Couldn't look for headsets: \(Self.describe(error))"))
        default:
            break
        }
    }

    private func servicesMaybeReady() {
        guard listenerReady, browserReady else { return }
        serviceProblem = nil
        serviceBackoff = Self.minBackoff
        updateState()
    }

    private func servicesFailed(_ problem: PeerLinkState) {
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        generation += 1
        listenerReady = false
        browserReady = false
        serviceProblem = problem
        updateState()
        resultsChanged([])
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard started, restartWork == nil else { return }
        let delay = serviceBackoff
        serviceBackoff = min(delay * 2, Self.maxBackoff)
        let work = DispatchWorkItem { [weak self] in
            onMain {
                guard let self, self.started else { return }
                self.restartWork = nil
                self.startServices()
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func wifiChanged(_ available: Bool) {
        let regained = available && !wifiAvailable
        wifiAvailable = available
        if regained, let work = restartWork {
            work.cancel()
            restartWork = nil
            serviceBackoff = Self.minBackoff
            startServices()
        }
        updateState()
    }

    private func updateState() {
        let new: PeerLinkState
        if !started {
            new = .off
        } else if !wifiAvailable {
            new = .noWiFi
        } else {
            new = serviceProblem ?? .running
        }
        guard new != state else { return }
        state = new
        delegate?.peerLink(self, stateChanged: new)
    }

    private func resultsChanged(_ results: Set<NWBrowser.Result>) {
        var found: [UUID: NWEndpoint] = [:]
        for result in results {
            guard let device = Self.deviceID(of: result), device != deviceID else { continue }
            found[device] = result.endpoint
        }
        let changed = Set(found.keys) != Set(advertised.keys)
        for device in advertised.keys where found[device] == nil {
            redials.removeValue(forKey: device)?.cancel()
        }
        advertised = found
        if changed { delegate?.peerLink(self, nearby: Set(found.keys)) }
        for device in found.keys { dialIfNeeded(device) }
    }

    private static func deviceID(of result: NWBrowser.Result) -> UUID? {
        if case .bonjour(let txt) = result.metadata,
           let value = txt[PeerProtocol.deviceIDKey],
           let device = UUID(uuidString: value) {
            return device
        }
        if case .service(let name, _, _, _) = result.endpoint {
            return UUID(uuidString: name)
        }
        return nil
    }

    // MARK: Connections

    private func dialIfNeeded(_ device: UUID) {
        guard started,
              deviceID.uuidString < device.uuidString,
              let endpoint = advertised[device],
              redials[device] == nil,
              !peers.values.contains(where: { $0.dialed && $0.deviceID == device })
        else { return }
        open(NWConnection(to: endpoint, using: Self.connectionParameters()), deviceID: device, dialed: true)
    }

    private func scheduleRedial(_ device: UUID) {
        guard started, advertised[device] != nil, redials[device] == nil else { return }
        let delay = dialBackoff[device] ?? Self.minBackoff
        dialBackoff[device] = min(delay * 2, Self.maxBackoff)
        let work = DispatchWorkItem { [weak self] in
            onMain {
                guard let self else { return }
                self.redials[device] = nil
                self.dialIfNeeded(device)
            }
        }
        redials[device] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func open(_ connection: NWConnection, deviceID device: UUID?, dialed: Bool) {
        let id = PeerConnectionID()
        peers[id] = Peer(connection: connection, deviceID: device, dialed: dialed)
        connection.stateUpdateHandler = { [weak self] state in
            onMain { self?.connectionChanged(id, state) }
        }
        connection.start(queue: .main)
    }

    private func connectionChanged(_ id: PeerConnectionID, _ state: NWConnection.State) {
        guard let peer = peers[id] else { return }
        switch state {
        case .ready:
            guard peer.readyAt == nil else { return }
            peer.readyAt = Date()
            delegate?.peerLink(self, connected: id, deviceID: peer.deviceID)
            receive(id)
            pump(id)
        case .waiting(let error), .failed(let error):
            end(id, error: Self.describe(error))
        case .cancelled:
            end(id, error: nil)
        default:
            break
        }
    }

    private func receive(_ id: PeerConnectionID) {
        guard let peer = peers[id] else { return }
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            onMain { self?.received(id, data: data, isComplete: isComplete, error: error) }
        }
    }

    private func received(_ id: PeerConnectionID, data: Data?, isComplete: Bool, error: NWError?) {
        guard let peer = peers[id] else { return }
        if let data, !data.isEmpty {
            let results: [Result<PeerMessage, PeerRejection>]
            do {
                results = try peer.reader.append(data)
            } catch {
                end(id, error: "sent an oversized message")
                return
            }
            for result in results {
                guard peers[id] != nil else { return }
                switch result {
                case .success(let message):
                    delegate?.peerLink(self, received: message, from: id)
                case .failure(let reason):
                    delegate?.peerLink(self, rejected: reason, from: id)
                }
            }
            guard peers[id] != nil else { return }
        }
        if let error {
            end(id, error: Self.describe(error))
        } else if isComplete {
            end(id, error: nil)
        } else {
            receive(id)
        }
    }

    private func pump(_ id: PeerConnectionID) {
        guard let peer = peers[id], peer.readyAt != nil, !peer.sending, peer.queueHead < peer.queue.count else { return }
        let frame = peer.queue[peer.queueHead]
        peer.queueHead += 1
        if peer.queueHead == peer.queue.count {
            peer.queue.removeAll()
            peer.queueHead = 0
        }
        peer.sending = true
        peer.connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            onMain { self?.sent(id, error: error) }
        })
    }

    private func sent(_ id: PeerConnectionID, error: NWError?) {
        guard let peer = peers[id] else { return }
        peer.sending = false
        if let error {
            end(id, error: Self.describe(error))
        } else {
            pump(id)
        }
    }

    private func end(_ id: PeerConnectionID, error: String?) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.connection.stateUpdateHandler = nil
        peer.connection.cancel()
        if let device = peer.deviceID, peer.dialed,
           let readyAt = peer.readyAt, Date().timeIntervalSince(readyAt) >= Self.stableAfter {
            dialBackoff[device] = nil
        }
        delegate?.peerLink(self, disconnected: id, deviceID: peer.deviceID, error: error)
        if peer.dialed, let device = peer.deviceID { scheduleRedial(device) }
    }

    private static func connectionParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    private static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == policyDenied }
        return false
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error {
            switch code {
            case .ECONNREFUSED: return "refused the connection"
            case .ETIMEDOUT: return "stopped responding"
            case .ECONNRESET, .ECONNABORTED, .EPIPE: return "dropped the connection"
            case .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH, .EHOSTDOWN: return "is out of reach"
            default: break
            }
        }
        if isPolicyDenied(error) { return "local network access is off" }
        return error.localizedDescription
    }
}

/// Network callbacks are delivered on `.main`, which is the main actor's queue.
private func onMain(_ body: @MainActor () -> Void) {
    MainActor.assumeIsolated(body)
}
