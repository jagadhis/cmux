import Foundation

/// A T3 Code thread, as read from T3's local state database.
public struct T3Thread: Identifiable, Hashable, Sendable {
    /// The T3 thread id.
    public var id: String
    /// The T3 project id.
    public var projectId: String
    /// The T3 project title, or `nil` when the project is unknown.
    public var projectName: String?
    /// The T3 project's root directory, when known.
    public var projectRoot: String?
    /// The thread title.
    public var title: String
    /// The branch the thread worked on.
    public var branch: String?
    /// The worktree or directory the thread worked in.
    public var worktreePath: String?
    /// The provider instance id, such as `claudeAgent` or `codex`.
    public var provider: String
    /// When the thread was created.
    public var createdAt: Date?
    /// When the thread was last updated.
    public var updatedAt: Date?
    /// Pull requests linked to the thread.
    public var pullRequests: [PullRequest]
    /// The thread that created this one (a sub-thread's parent), if any.
    public var parentThreadId: String?
    /// The top of this thread's lineage, if it has a parent.
    public var rootThreadId: String?
    /// How this thread relates to its parent, such as `subagent` or `fork`.
    public var relationshipToParent: String?
    /// The thread whose agent started this one as a new top-level thread
    /// (`t3_thread_launch` or `create_threads`): a handoff, not a sub-thread.
    public var launchedByThreadId: String?
    /// The status of the thread's latest run, such as `running` or `completed`.
    public var latestRunStatus: String?
    /// Whether the thread has a request waiting on the user.
    public var hasPendingRequest: Bool
    /// When the thread's latest run finished, if it has.
    public var latestRunCompletedAt: Date?
    /// When the user last looked at the thread, in T3 or in cmux.
    public var lastVisitedAt: Date?
    /// Whether the user settled the thread in T3 (marked it verified).
    public var isSettled: Bool
    /// The sub-agent behind the thread, when an agent started it as one.
    public var subagent: Subagent?

    /// Creates a T3 thread.
    ///
    /// - Parameters:
    ///   - id: The T3 thread id.
    ///   - projectId: The T3 project id.
    ///   - projectName: The T3 project title.
    ///   - projectRoot: The T3 project's root directory.
    ///   - title: The thread title.
    ///   - branch: The branch the thread worked on.
    ///   - worktreePath: The worktree or directory the thread worked in.
    ///   - provider: The provider instance id.
    ///   - createdAt: When the thread was created.
    ///   - updatedAt: When the thread was last updated.
    ///   - pullRequests: Pull requests linked to the thread.
    ///   - parentThreadId: The thread that created this one.
    ///   - rootThreadId: The top of this thread's lineage.
    ///   - relationshipToParent: How this thread relates to its parent.
    ///   - launchedByThreadId: The thread whose agent started this one as a new thread.
    ///   - latestRunStatus: The status of the thread's latest run.
    ///   - hasPendingRequest: Whether a request is waiting on the user.
    ///   - latestRunCompletedAt: When the latest run finished.
    ///   - lastVisitedAt: When the user last looked at the thread.
    ///   - isSettled: Whether the user settled the thread.
    ///   - subagent: The sub-agent behind the thread.
    public init(
        id: String,
        projectId: String,
        projectName: String?,
        projectRoot: String? = nil,
        title: String,
        branch: String? = nil,
        worktreePath: String? = nil,
        provider: String,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        pullRequests: [PullRequest] = [],
        parentThreadId: String? = nil,
        rootThreadId: String? = nil,
        relationshipToParent: String? = nil,
        launchedByThreadId: String? = nil,
        latestRunStatus: String? = nil,
        hasPendingRequest: Bool = false,
        latestRunCompletedAt: Date? = nil,
        lastVisitedAt: Date? = nil,
        isSettled: Bool = false,
        subagent: Subagent? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.projectName = projectName
        self.projectRoot = projectRoot
        self.title = title
        self.branch = branch
        self.worktreePath = worktreePath
        self.provider = provider
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pullRequests = pullRequests
        self.parentThreadId = parentThreadId
        self.rootThreadId = rootThreadId
        self.relationshipToParent = relationshipToParent
        self.launchedByThreadId = launchedByThreadId
        self.latestRunStatus = latestRunStatus
        self.hasPendingRequest = hasPendingRequest
        self.latestRunCompletedAt = latestRunCompletedAt
        self.lastVisitedAt = lastVisitedAt
        self.isSettled = isSettled
        self.subagent = subagent
    }

    /// Whether the latest run finished after the user last looked, as T3 counts it.
    /// A thread T3 has never recorded a visit for doesn't count.
    public var hasUnseenResult: Bool {
        guard let completed = latestRunCompletedAt, let visited = lastVisitedAt else { return false }
        return completed > visited
    }

    /// Whether the latest run ended without finishing: failed, interrupted or
    /// cancelled. A sub-agent with no runs of its own counts by its own status.
    public var latestRunEndedEarly: Bool {
        ["failed", "interrupted", "cancelled"].contains(latestRunStatus ?? subagent?.status ?? "")
    }

    /// The agent behind the thread, from its provider instance id.
    public var agentKind: AgentHomeAgentKind {
        let provider = provider.lowercased()
        if provider.hasPrefix("claude") { return .claude }
        if provider.hasPrefix("codex") { return .codex }
        if provider.hasPrefix("opencode") { return .opencode }
        return .other(self.provider)
    }
}
