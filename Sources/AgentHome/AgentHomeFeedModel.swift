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
///
/// Folding the Feed (up to its ring capacity of items) is the expensive part,
/// so the result is kept until the Feed or the resolved targets change.
@MainActor
@Observable
final class AgentHomeFeedModel {
    static let shared = AgentHomeFeedModel()

    private(set) var targets: [String: FeedJumpResolver.Target] = [:]

    /// What the cached signals were folded from. The store's revision moves
    /// on every item change; the rest guards against a store swap or a
    /// revision restored from disk.
    private struct FoldKey: Equatable {
        var store: ObjectIdentifier?
        var revision: Int
        var count: Int
        var firstId: UUID?
        var lastId: UUID?
        var lastUpdatedAt: Date?
        var targetCount: Int
    }

    /// A memo, not view state: filled from `body`, so it must not be observed.
    @ObservationIgnored private var cachedSignals: (key: FoldKey, signals: [String: AgentHomeFeedSignals])?
    private let fold = AgentHomeFeedFold()

    private var store: WorkstreamStore? { FeedCoordinator.shared.store }

    /// Every Feed item, or none while the Feed store isn't installed yet.
    var items: [WorkstreamItem] {
        store?.items ?? []
    }

    /// Workstream ids in the Feed.
    var workstreamIDs: [String] {
        Array(Set(items.map(\.workstreamId))).sorted()
    }

    /// Changes whenever Feed items arrive. Used as the `.task` id that retries
    /// lookups: a new session's first items can land before its hook-session
    /// record is written, so a lookup that failed is retried on the next item.
    var resolutionToken: Int { items.count }

    /// Signals per terminal, keyed by uppercased panel id. Folds the Feed only
    /// when it or the resolved targets changed since the last call.
    func signals() -> [String: AgentHomeFeedSignals] {
        let store = store
        let items = store?.items ?? []
        let key = FoldKey(
            store: store.map(ObjectIdentifier.init),
            revision: store?.revision ?? 0,
            count: items.count,
            firstId: items.first?.id,
            lastId: items.last?.id,
            lastUpdatedAt: items.last?.updatedAt,
            targetCount: targets.count
        )
        if let cachedSignals, cachedSignals.key == key { return cachedSignals.signals }
        let signals = fold.signals(for: AgentHomeFeedIndex.events(items: items, targets: targets))
        cachedSignals = (key, signals)
        return signals
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

    /// A page that fills the main area instead of the selected task.
    enum Page: Hashable {
        case pullRequests
        case usage
        /// One pull request, in the detail view.
        case pullRequest(GitHubPullRequestRef)
    }

    /// The page shown instead of the selected task, if any.
    var page: Page? {
        didSet { if case .pullRequest = page {} else { pullRequestBackStack = [] } }
    }

    /// Whether the main area shows pull requests: the list or one in detail.
    var isShowingPullRequests: Bool {
        if case .pullRequest = page { return true }
        return page == .pullRequests
    }

    /// Where Back goes from a pull request's detail: the pages it was opened from.
    private(set) var pullRequestBackStack: [Page?] = []

    /// Shows a pull request's detail, remembering where Back goes.
    func showPullRequest(_ ref: GitHubPullRequestRef) {
        if case .pullRequest(let current) = page, current == ref { return }
        let previous = page
        let stack = pullRequestBackStack
        page = .pullRequest(ref)
        pullRequestBackStack = stack + [previous]
    }

    /// Leaves the pull request detail for the page it was opened from.
    func goBackFromPullRequest() {
        var stack = pullRequestBackStack
        let previous = stack.popLast() ?? nil
        page = previous
        pullRequestBackStack = stack
    }

    /// Shows a page, or goes back to the selected task when it's already showing.
    func togglePage(_ page: Page) {
        self.page = self.page == page ? nil : page
    }

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
