import Combine
import Foundation
import GroupActivities
import Observation

/// A SharePlay session whose only purpose is a world anchor shared between the headsets in the
/// room, which lines their scans up exactly.
struct LineUpActivity: GroupActivity {
    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.title = "Line up headsets"
        metadata.type = .generic
        return metadata
    }
}

/// Joins `LineUpActivity` sessions and, while people nearby take part, has the headset chosen by
/// `SiteSharing.shouldCreateSharedAnchor` create one shared world anchor per session.
@MainActor
@Observable
final class SharedAnchorSession {
    enum State: Equatable {
        case idle
        case waiting
        case active(nearby: Int)
        case failed(String)

        var label: String? {
            switch self {
            case .idle: nil
            case .waiting: "Waiting for people nearby to join…"
            case .active(let nearby): "SharePlay on with \(nearby) \(nearby == 1 ? "person" : "people") nearby"
            case .failed(let message): "SharePlay failed: \(message)"
            }
        }
    }

    private(set) var state: State = .idle
    @ObservationIgnored weak var sharing: SiteSharing?
    @ObservationIgnored private let scene: SceneController
    @ObservationIgnored private var session: GroupSession<LineUpActivity>?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(scene: SceneController) {
        self.scene = scene
        Task { [weak self] in
            for await session in LineUpActivity.sessions() {
                await self?.join(session)
            }
        }
    }

    /// Offers the share menu; the session arrives through `LineUpActivity.sessions()`.
    func start() {
        Task {
            do {
                _ = try await LineUpActivity().activate()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func join(_ session: GroupSession<LineUpActivity>) async {
        self.session?.leave()
        end()
        self.session = session
        state = .waiting
        if let coordinator = await session.systemCoordinator {
            coordinator.configuration.supportsGroupImmersiveSpace = true
        }
        session.join()
        tasks = [
            Task { [weak self] in
                for await participants in session.$activeParticipants.values {
                    self?.update(participants, local: session.localParticipant)
                }
            },
            Task { [weak self] in
                for await state in session.$state.values {
                    if case .invalidated = state {
                        self?.ended(session)
                        return
                    }
                }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled else { return }
                    if await createAnchorIfNeeded() { return }
                }
            },
        ]
    }

    private func update(_ participants: Set<Participant>, local: Participant) {
        let nearby = participants.filter { $0 != local && $0.isNearbyWithLocalParticipant }.count
        state = nearby > 0 ? .active(nearby: nearby) : .waiting
    }

    private func createAnchorIfNeeded() async -> Bool {
        guard case .active = state, scene.anchorSharingAvailable, let sharing, sharing.shouldCreateSharedAnchor,
              let anchor = await scene.addSharedAnchor() else { return false }
        sharing.publishSharedAnchor(id: anchor.id, originFromAnchor: anchor.originFromAnchor)
        return true
    }

    private func ended(_ ended: GroupSession<LineUpActivity>) {
        guard ended === session else { return }
        end()
        state = .idle
    }

    private func end() {
        tasks.forEach { $0.cancel() }
        tasks = []
        session = nil
    }
}
