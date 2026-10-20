import Foundation

/// The coding agent behind an Agent Home card.
public enum AgentHomeAgentKind: Hashable, Sendable {
    case claude
    case codex
    case opencode
    /// Any other agent cmux has a hook integration for, by its CLI name.
    case other(String)

    /// The display name shown on agent cards and in the composer picker.
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .other(let name): return name
        }
    }

    /// Creates a kind from the agent key cmux's hook stores use, such as `claude` or `codex`.
    ///
    /// - Parameter hookAgentKey: The agent key, compared case-insensitively.
    public init(hookAgentKey: String) {
        switch hookAgentKey.lowercased() {
        case "claude", "claude-code", "claudecode": self = .claude
        case "codex": self = .codex
        case "opencode": self = .opencode
        default: self = .other(hookAgentKey)
        }
    }
}

/// What an agent is doing, reduced to the states Agent Home draws.
public enum AgentHomeAgentState: String, Sendable, CaseIterable {
    /// The agent is waiting on the user: a permission prompt or a question.
    case needsYou
    /// The agent is working.
    case running
    /// The agent finished its turn and is waiting for the next message.
    case idle
}

/// One step of an agent's plan, from Claude's `TodoWrite` or an equivalent.
public struct AgentHomePlanStep: Hashable, Sendable {
    /// Where a plan step stands.
    public enum Status: String, Sendable {
        case pending
        case inProgress
        case completed
    }

    /// The step's text.
    public var title: String
    /// Where the step stands.
    public var status: Status

    /// Creates a plan step.
    ///
    /// - Parameters:
    ///   - title: The step's text.
    ///   - status: Where the step stands.
    public init(title: String, status: Status) {
        self.title = title
        self.status = status
    }
}

/// A permission prompt an agent is blocked on.
public struct AgentHomePermissionRequest: Hashable, Sendable {
    /// The Feed request id used to deliver the reply.
    public var requestId: String
    /// The tool the agent wants to run, such as `Bash`.
    public var toolName: String
    /// A one-line summary of what will run, such as the shell command.
    public var summary: String
    /// Whether "Always allow" can be offered for this request.
    public var canAlwaysAllow: Bool

    /// Creates a permission request.
    ///
    /// - Parameters:
    ///   - requestId: The Feed request id used to deliver the reply.
    ///   - toolName: The tool the agent wants to run.
    ///   - summary: A one-line summary of what will run.
    ///   - canAlwaysAllow: Whether "Always allow" can be offered.
    public init(requestId: String, toolName: String, summary: String, canAlwaysAllow: Bool) {
        self.requestId = requestId
        self.toolName = toolName
        self.summary = summary
        self.canAlwaysAllow = canAlwaysAllow
    }
}

/// One agent session inside a task, as an Agent Home card shows it.
public struct AgentHomeAgent: Identifiable, Hashable, Sendable {
    /// A stable id for the session, such as the panel id plus agent key.
    public var id: String
    /// The agent behind the session.
    public var kind: AgentHomeAgentKind
    /// The card title: the session or tab title.
    public var title: String
    /// The model's display name, when known.
    public var modelName: String?
    /// What the agent is doing.
    public var state: AgentHomeAgentState
    /// When the session started, for the elapsed-time label.
    public var startedAt: Date?
    /// When the agent last did something, for "23h ago" labels on idle cards.
    public var lastActivityAt: Date?
    /// The fraction of the context window in use, from 0 to 1.
    public var contextFraction: Double?
    /// The estimated cost of the session so far, in US dollars.
    public var estimatedCostUSD: Double?
    /// The live "doing now" line, such as "Reading relay.ts".
    public var currentActivity: String?
    /// The agent's last reply, shown on idle cards.
    public var lastSummary: String?
    /// The agent's plan, empty when it has none.
    public var plan: [AgentHomePlanStep]
    /// The permission prompt the agent is blocked on, if any.
    public var pendingPermission: AgentHomePermissionRequest?

    /// Creates an agent card model.
    ///
    /// - Parameters:
    ///   - id: A stable id for the session.
    ///   - kind: The agent behind the session.
    ///   - title: The card title.
    ///   - modelName: The model's display name, when known.
    ///   - state: What the agent is doing. A pending permission forces ``AgentHomeAgentState/needsYou``.
    ///   - startedAt: When the session started.
    ///   - lastActivityAt: When the agent last did something.
    ///   - contextFraction: The fraction of the context window in use, clamped to 0...1.
    ///   - estimatedCostUSD: The estimated cost so far.
    ///   - currentActivity: The live "doing now" line.
    ///   - lastSummary: The agent's last reply.
    ///   - plan: The agent's plan.
    ///   - pendingPermission: The permission prompt the agent is blocked on.
    public init(
        id: String,
        kind: AgentHomeAgentKind,
        title: String,
        modelName: String? = nil,
        state: AgentHomeAgentState,
        startedAt: Date? = nil,
        lastActivityAt: Date? = nil,
        contextFraction: Double? = nil,
        estimatedCostUSD: Double? = nil,
        currentActivity: String? = nil,
        lastSummary: String? = nil,
        plan: [AgentHomePlanStep] = [],
        pendingPermission: AgentHomePermissionRequest? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.modelName = modelName
        self.state = pendingPermission == nil ? state : .needsYou
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.contextFraction = contextFraction.map { min(max($0, 0), 1) }
        self.estimatedCostUSD = estimatedCostUSD
        self.currentActivity = currentActivity
        self.lastSummary = lastSummary
        self.plan = plan
        self.pendingPermission = pendingPermission
    }

    /// The plan step the agent is on: the first step that isn't completed.
    public var currentPlanStep: AgentHomePlanStep? {
        plan.first { $0.status != .completed }
    }
}

/// A pull request's state and checks, as the task header and PR card show them.
public struct AgentHomePullRequest: Hashable, Sendable {
    /// The pull request's lifecycle state.
    public enum State: String, Sendable {
        case open
        case merged
        case closed
    }

    /// One CI check on the pull request.
    public struct Check: Hashable, Sendable {
        /// A check's outcome.
        public enum Outcome: String, Sendable {
            case pending
            case passed
            case failed
        }

        /// The check's name.
        public var name: String
        /// The check's outcome.
        public var outcome: Outcome
        /// How long the check took, or has been running.
        public var duration: TimeInterval?

        /// Creates a check.
        ///
        /// - Parameters:
        ///   - name: The check's name.
        ///   - outcome: The check's outcome.
        ///   - duration: How long the check took.
        public init(name: String, outcome: Outcome, duration: TimeInterval? = nil) {
            self.name = name
            self.outcome = outcome
            self.duration = duration
        }
    }

    /// The pull request number.
    public var number: Int
    /// The pull request title.
    public var title: String
    /// The pull request URL.
    public var url: URL?
    /// The lifecycle state.
    public var state: State
    /// The CI checks, empty when unknown.
    public var checks: [Check]

    /// Creates a pull request model.
    ///
    /// - Parameters:
    ///   - number: The pull request number.
    ///   - title: The pull request title.
    ///   - url: The pull request URL.
    ///   - state: The lifecycle state.
    ///   - checks: The CI checks.
    public init(number: Int, title: String, url: URL? = nil, state: State, checks: [Check] = []) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.checks = checks
    }

    /// The number of checks that passed.
    public var passedCheckCount: Int { checks.filter { $0.outcome == .passed }.count }
}

/// A changed file in a task's working tree.
public struct AgentHomeChangedFile: Hashable, Sendable {
    /// The repository-relative path.
    public var path: String
    /// Lines added.
    public var additions: Int
    /// Lines deleted.
    public var deletions: Int

    /// Creates a changed file.
    ///
    /// - Parameters:
    ///   - path: The repository-relative path.
    ///   - additions: Lines added.
    ///   - deletions: Lines deleted.
    public init(path: String, additions: Int, deletions: Int) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
    }

    /// The directory part of ``path`` with a trailing slash, or an empty string at the root.
    public var directory: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[...slash])
    }

    /// The file name part of ``path``.
    public var fileName: String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}

/// The workspace lane a task is in, mirroring cmux's `WorkspaceTaskStatus`.
///
/// The app maps `WorkspaceTaskStatus` (inferred or pinned) into this, so
/// Agent Home and the classic sidebar always agree on a task's status.
public enum AgentHomeTaskLane: String, Sendable {
    case todo
    case working
    case needsAttention
    case review
    case done
}

/// One task (a cmux workspace) as Agent Home receives it from the app.
public struct AgentHomeTaskInput: Hashable, Sendable {
    /// The workspace id.
    public var id: UUID
    /// The workspace title.
    public var title: String
    /// The workspace group id, or `nil` for a task that isn't in a project.
    public var projectId: UUID?
    /// The task's lane, from `WorkspaceTaskStatus`.
    public var lane: AgentHomeTaskLane
    /// The checked-out branch.
    public var branch: String?
    /// The working directory or worktree path.
    public var directory: String?
    /// The pull request for the branch.
    public var pullRequest: AgentHomePullRequest?
    /// The task's agent sessions.
    public var agents: [AgentHomeAgent]
    /// Changed files in the working tree.
    public var changedFiles: [AgentHomeChangedFile]
    /// When the task was created.
    public var createdAt: Date?

    /// Creates a task input.
    ///
    /// - Parameters:
    ///   - id: The workspace id.
    ///   - title: The workspace title.
    ///   - projectId: The workspace group id.
    ///   - lane: The task's lane.
    ///   - branch: The checked-out branch.
    ///   - directory: The working directory or worktree path.
    ///   - pullRequest: The pull request for the branch.
    ///   - agents: The task's agent sessions.
    ///   - changedFiles: Changed files in the working tree.
    ///   - createdAt: When the task was created.
    public init(
        id: UUID,
        title: String,
        projectId: UUID? = nil,
        lane: AgentHomeTaskLane = .todo,
        branch: String? = nil,
        directory: String? = nil,
        pullRequest: AgentHomePullRequest? = nil,
        agents: [AgentHomeAgent] = [],
        changedFiles: [AgentHomeChangedFile] = [],
        createdAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.projectId = projectId
        self.lane = lane
        self.branch = branch
        self.directory = directory
        self.pullRequest = pullRequest
        self.agents = agents
        self.changedFiles = changedFiles
        self.createdAt = createdAt
    }
}

/// One project (a cmux workspace group) as Agent Home receives it from the app.
public struct AgentHomeProjectInput: Hashable, Sendable {
    /// The workspace group id.
    public var id: UUID
    /// The group name.
    public var name: String
    /// The group colour as a hex string such as `#D9734A`, when set.
    public var colorHex: String?
    /// The workspace that is the project's home: the group's anchor, opened
    /// from the project row rather than listed as a task.
    public var homeTaskId: UUID?

    /// Creates a project input.
    ///
    /// - Parameters:
    ///   - id: The workspace group id.
    ///   - name: The group name.
    ///   - colorHex: The group colour as a hex string.
    ///   - homeTaskId: The workspace that is the project's home, if any.
    public init(id: UUID, name: String, colorHex: String? = nil, homeTaskId: UUID? = nil) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.homeTaskId = homeTaskId
    }
}
