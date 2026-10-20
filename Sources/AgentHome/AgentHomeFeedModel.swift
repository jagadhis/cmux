import CMUXAgentLaunch
import CmuxAgentHome
import Foundation
import Observation

/// Feed signals for Agent Home, shared by the sidebar and the task overview.
///
/// Feed items name a workstream, not a terminal. Resolving a workstream to
/// its workspace and terminal reads hook-session files, so it runs async and
/// the results are cached here. Views read ``signals()`` from `body`, which
/// tracks both the Feed store and the cache, and call ``resolveTargets(for:)``
/// from `.task`, never from `body`.
@MainActor
@Observable
final class AgentHomeFeedModel {
    static let shared = AgentHomeFeedModel()

    private(set) var targets: [String: FeedJumpResolver.Target] = [:]

    /// Every Feed item, or none while the Feed store isn't installed yet.
    var items: [WorkstreamItem] {
        let store: WorkstreamStore? = FeedCoordinator.shared.store
        return store?.items ?? []
    }

    /// Workstream ids in the Feed.
    var workstreamIDs: [String] {
        Array(Set(items.map(\.workstreamId))).sorted()
    }

    /// Changes whenever Feed items arrive. Used as the `.task` id that retries
    /// lookups: a new session's first items can land before its hook-session
    /// record is written, so a lookup that failed is retried on the next item.
    var resolutionToken: Int { items.count }

    /// Signals per terminal, keyed by uppercased panel id.
    func signals() -> [String: AgentHomeFeedSignals] {
        AgentHomeFeedIndex.signals(items: items, targets: targets)
    }

    /// Resolves workstreams that aren't cached yet.
    func resolveTargets(for workstreamIDs: [String]) async {
        let missing = workstreamIDs.filter { targets[$0] == nil }
        guard !missing.isEmpty else { return }
        let resolved = await FeedCoordinator.shared.resolveTargets(for: missing)
        guard !resolved.isEmpty else { return }
        targets.merge(resolved) { _, new in new }
    }

    /// Answers a permission request from an agent card.
    func reply(to request: AgentHomePermissionRequest, mode: WorkstreamPermissionMode) {
        FeedCoordinator.shared.deliverReply(requestId: request.requestId, decision: .permission(mode))
    }
}

/// Which view a task shows in the main area while Agent Home is the sidebar.
@MainActor
@Observable
final class AgentHomeTaskViewState {
    enum Mode: Hashable {
        case overview
        case sessions
    }

    static let shared = AgentHomeTaskViewState()

    /// Whether the main area shows the pull requests list instead of the selected task.
    var showsPullRequests = false

    /// A New chat waiting to be shown, with a project and text filled in.
    struct NewChatRequest: Identifiable {
        let id = UUID()
        var projectId: String?
        var text: String = ""
    }

    /// The New chat sheet's request, set by the sidebar button or "Review with agent".
    var newChatRequest: NewChatRequest?

    private var overrides: [UUID: Mode] = [:]

    /// The task's mode: what the user last picked, else Overview for tasks
    /// with agents and Sessions (the terminals) for plain shells.
    func mode(for task: AgentHomeTask) -> Mode {
        mode(forTaskId: task.id, hasAgents: !task.input.agents.isEmpty)
    }

    func mode(forTaskId taskId: UUID, hasAgents: Bool) -> Mode {
        overrides[taskId] ?? (hasAgents ? .overview : .sessions)
    }

    func setMode(_ mode: Mode, for taskId: UUID) {
        overrides[taskId] = mode
    }
}
