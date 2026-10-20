import Foundation

/// A task's status as Agent Home shows it, most urgent first.
public enum AgentHomeTaskStatus: Int, Sendable, CaseIterable, Comparable {
    /// An agent is waiting on the user.
    case needsYou
    /// An agent is working.
    case running
    /// The work is done and an open pull request is waiting for review.
    case readyForReview
    /// Nothing is running and nothing is waiting.
    case idle
    /// The task's pull requests are merged or closed.
    case done

    public static func < (lhs: AgentHomeTaskStatus, rhs: AgentHomeTaskStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The sidebar views at the top of Agent Home.
public enum AgentHomeFilter: Sendable, CaseIterable {
    case needsYou
    case running
    case readyForReview

    var status: AgentHomeTaskStatus {
        switch self {
        case .needsYou: return .needsYou
        case .running: return .running
        case .readyForReview: return .readyForReview
        }
    }
}

/// A task with its derived status and totals.
public struct AgentHomeTask: Identifiable, Hashable, Sendable {
    /// The task as the app supplied it.
    public var input: AgentHomeTaskInput
    /// The derived status.
    public var status: AgentHomeTaskStatus

    /// The workspace id.
    public var id: UUID { input.id }

    /// Agents that are running or waiting on the user.
    public var liveAgentCount: Int {
        input.agents.filter { $0.state != .idle }.count
    }

    /// The summed estimated cost of every agent session, or `nil` when none reported one.
    public var estimatedCostUSD: Double? {
        let costs = input.agents.compactMap(\.estimatedCostUSD)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    /// When work on the task started: its earliest agent session, else its creation date.
    public var startedAt: Date? {
        input.agents.compactMap(\.startedAt).min() ?? input.createdAt
    }

    /// Total lines added across changed files.
    public var additions: Int { input.changedFiles.reduce(0) { $0 + $1.additions } }

    /// Total lines deleted across changed files.
    public var deletions: Int { input.changedFiles.reduce(0) { $0 + $1.deletions } }

    /// The permission requests waiting in this task, in agent order.
    public var pendingPermissions: [AgentHomePermissionRequest] {
        input.agents.compactMap(\.pendingPermission)
    }
}

/// A project with its tasks in sidebar order.
public struct AgentHomeProject: Identifiable, Hashable, Sendable {
    /// The project as the app supplied it.
    public var input: AgentHomeProjectInput
    /// The project's home workspace, opened from the project row. Not listed among ``tasks``.
    public var home: AgentHomeTask?
    /// The project's tasks, in workspace order, without the home workspace.
    public var tasks: [AgentHomeTask]

    /// The workspace group id.
    public var id: UUID { input.id }

    /// The most urgent status among the project's home and tasks, shown on a collapsed project row.
    public var rollupStatus: AgentHomeTaskStatus? { ((home.map { [$0] } ?? []) + tasks).map(\.status).min() }
}

/// Everything the Agent Home sidebar and task views draw, derived from app state.
public struct AgentHomeSnapshot: Hashable, Sendable {
    /// Projects in group order, each with its tasks.
    public var projects: [AgentHomeProject]
    /// Tasks that aren't in any project, in workspace order.
    public var ungroupedTasks: [AgentHomeTask]

    /// Every task including project homes: each project's home then its tasks, then ungrouped tasks.
    public var allTasks: [AgentHomeTask] {
        projects.flatMap { ($0.home.map { [$0] } ?? []) + $0.tasks } + ungroupedTasks
    }

    /// The tasks listed as rows, in sidebar order: project tasks, then ungrouped tasks.
    public var listedTasks: [AgentHomeTask] { projects.flatMap(\.tasks) + ungroupedTasks }

    /// The tasks shown by a sidebar view, in sidebar order.
    ///
    /// - Parameter filter: The sidebar view.
    /// - Returns: The tasks whose status matches the view.
    public func tasks(matching filter: AgentHomeFilter) -> [AgentHomeTask] {
        allTasks.filter { $0.status == filter.status }
    }

    /// The number of tasks a sidebar view shows.
    ///
    /// - Parameter filter: The sidebar view.
    /// - Returns: The count for the view's badge.
    public func count(of filter: AgentHomeFilter) -> Int {
        tasks(matching: filter).count
    }

    /// The listed task ⌘1 through ⌘9 select, in sidebar order.
    ///
    /// - Parameter number: The shortcut number, 1 through 9.
    /// - Returns: The task id, or `nil` when there are fewer tasks or the number is out of range.
    public func taskId(forShortcut number: Int) -> UUID? {
        guard (1...9).contains(number) else { return nil }
        let tasks = listedTasks
        return number <= tasks.count ? tasks[number - 1].id : nil
    }

    /// Agents that are running or waiting on the user, across every task.
    public var liveAgentCount: Int { allTasks.reduce(0) { $0 + $1.liveAgentCount } }

    /// The task looked up by workspace id.
    ///
    /// - Parameter id: The workspace id.
    /// - Returns: The task, or `nil` when no task has that id.
    public func task(id: UUID) -> AgentHomeTask? {
        allTasks.first { $0.id == id }
    }
}

/// Builds an ``AgentHomeSnapshot`` from the app's workspaces and groups.
public enum AgentHomeProjection {
    /// Derives the Agent Home snapshot.
    ///
    /// Tasks keep the order they're given in, so the sidebar mirrors cmux's
    /// own workspace order. A task whose project id doesn't match any given
    /// project is treated as ungrouped.
    ///
    /// - Parameters:
    ///   - projects: Workspace groups, in group order.
    ///   - tasks: Workspaces, in workspace order.
    /// - Returns: The snapshot.
    public static func snapshot(
        projects: [AgentHomeProjectInput],
        tasks: [AgentHomeTaskInput]
    ) -> AgentHomeSnapshot {
        let derived = tasks.map { AgentHomeTask(input: $0, status: status(of: $0)) }
        let knownProjectIds = Set(projects.map(\.id))
        let byProject = Dictionary(grouping: derived.filter { $0.input.projectId.map(knownProjectIds.contains) == true }) {
            $0.input.projectId!
        }
        return AgentHomeSnapshot(
            projects: projects.map { project in
                let members = byProject[project.id] ?? []
                return AgentHomeProject(
                    input: project,
                    home: members.first { $0.id == project.homeTaskId },
                    tasks: members.filter { $0.id != project.homeTaskId }
                )
            },
            ungroupedTasks: derived.filter { $0.input.projectId.map(knownProjectIds.contains) != true }
        )
    }

    /// Derives one task's status.
    ///
    /// Live agent state wins over the workspace lane, because a permission
    /// prompt can arrive before the lane is re-inferred. Only a working agent
    /// makes a task ``AgentHomeTaskStatus/running``: the `working` lane is
    /// also inferred from a dirty git tree, which isn't live work. Otherwise
    /// the lane decides, with an open pull request on a quiet task reading as
    /// ready for review.
    ///
    /// - Parameter task: The task.
    /// - Returns: The derived status.
    public static func status(of task: AgentHomeTaskInput) -> AgentHomeTaskStatus {
        if task.agents.contains(where: { $0.state == .needsYou }) { return .needsYou }
        if task.agents.contains(where: { $0.state == .running }) { return .running }
        switch task.lane {
        case .needsAttention: return .needsYou
        case .working: return task.pullRequest?.state == .open ? .readyForReview : .idle
        case .review: return .readyForReview
        case .done: return .done
        case .todo:
            if task.pullRequest?.state == .open { return .readyForReview }
            if let state = task.pullRequest?.state, state != .open { return .done }
            return .idle
        }
    }
}
