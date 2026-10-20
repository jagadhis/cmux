import Foundation

/// A T3 thread's state as Agent Home shows it.
public enum T3ThreadStatus: Int, Sendable, Comparable {
    /// The thread's agent is waiting on the user.
    case needsYou
    /// The thread's agent is working.
    case running
    /// Nothing is running.
    case idle

    public static func < (lhs: T3ThreadStatus, rhs: T3ThreadStatus) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Run statuses that mean the agent is still going.
    public static let activeRunStatuses: Set<String> = ["preparing", "queued", "starting", "running", "waiting"]

    /// The status of one thread. A pending request only counts while a run is
    /// active, so a stale request on a finished thread doesn't raise "needs you".
    ///
    /// - Parameter thread: The thread.
    /// - Returns: Its status.
    public static func of(_ thread: T3Thread) -> T3ThreadStatus {
        guard let run = thread.latestRunStatus, activeRunStatuses.contains(run) else { return .idle }
        return thread.hasPendingRequest || run == "waiting" ? .needsYou : .running
    }
}

/// A task: a thread the user started, with every thread its agents created under it.
public struct T3TaskNode: Identifiable, Hashable, Sendable {
    /// The thread the user started.
    public var thread: T3Thread
    /// Sub-threads anywhere below it, most recently updated first.
    public var subThreads: [T3Thread]

    /// The task id: the root thread's id.
    public var id: String { thread.id }

    /// The most urgent status of the root thread and its sub-threads.
    public var status: T3ThreadStatus {
        ([thread] + subThreads).map(T3ThreadStatus.of).min() ?? .idle
    }

    /// Sub-threads that are running or waiting on the user.
    public var liveSubThreadCount: Int {
        subThreads.filter { T3ThreadStatus.of($0) != .idle }.count
    }

    /// When the root thread or any sub-thread last changed.
    public var lastActivity: Date? {
        ([thread] + subThreads).compactMap(\.updatedAt).max()
    }
}

/// A T3 project with its tasks, recent ones first.
public struct T3ProjectNode: Identifiable, Hashable, Sendable {
    /// The T3 project id, or an empty string for threads without a project.
    public var id: String
    /// The project name.
    public var name: String
    /// The project's root directory, when known.
    public var root: String?
    /// Tasks that are live or changed within the recent window, most recent first.
    public var recentTasks: [T3TaskNode]
    /// Older, quiet tasks, most recent first.
    public var olderTasks: [T3TaskNode]

    /// When any task in the project last changed.
    public var lastActivity: Date? {
        (recentTasks + olderTasks).compactMap(\.lastActivity).max()
    }
}

/// Builds the project → task → sub-thread tree from T3 threads.
public enum T3ThreadTree {
    /// How long a quiet task stays in a project's recent list.
    public static let defaultRecentWindow: TimeInterval = 7 * 24 * 60 * 60

    /// Builds the tree.
    ///
    /// A thread with a parent is a sub-thread of its lineage's root. When the
    /// root isn't among `threads` (archived or deleted), the sub-thread's
    /// nearest present ancestor takes its place, and with none present the
    /// sub-thread becomes a task of its own.
    ///
    /// - Parameters:
    ///   - threads: Active threads from T3.
    ///   - now: The current time, for the recent window.
    ///   - recentWindow: How long a quiet task counts as recent.
    /// - Returns: Projects ordered by latest activity, each with recent and older tasks.
    public static func build(
        _ threads: [T3Thread],
        now: Date = Date(),
        recentWindow: TimeInterval = defaultRecentWindow
    ) -> [T3ProjectNode] {
        let byId = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func taskRoot(of thread: T3Thread) -> String {
            if let root = thread.rootThreadId, root != thread.id, byId[root] != nil { return root }
            var current = thread
            var seen: Set<String> = [thread.id]
            while let parent = current.parentThreadId, let next = byId[parent], seen.insert(parent).inserted {
                current = next
            }
            return current.id
        }

        var subThreads: [String: [T3Thread]] = [:]
        var roots: [T3Thread] = []
        for thread in threads {
            let root = taskRoot(of: thread)
            if root == thread.id { roots.append(thread) } else { subThreads[root, default: []].append(thread) }
        }

        let tasks = roots.map { root in
            T3TaskNode(thread: root, subThreads: (subThreads[root.id] ?? []).sorted(by: updatedFirst))
        }
        let cutoff = now.addingTimeInterval(-recentWindow)
        var projects: [String: T3ProjectNode] = [:]
        for task in tasks {
            let key = task.thread.projectName == nil ? "" : task.thread.projectId
            var project = projects[key] ?? T3ProjectNode(
                id: key,
                name: task.thread.projectName ?? "",
                root: task.thread.projectRoot,
                recentTasks: [],
                olderTasks: []
            )
            let isRecent = task.status != .idle || (task.lastActivity ?? .distantPast) >= cutoff
            if isRecent { project.recentTasks.append(task) } else { project.olderTasks.append(task) }
            projects[key] = project
        }
        return projects.values
            .map { project in
                var project = project
                project.recentTasks.sort(by: taskOrder)
                project.olderTasks.sort(by: taskOrder)
                return project
            }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    /// Live tasks first (needs you, then running), then most recent activity.
    static func taskOrder(_ lhs: T3TaskNode, _ rhs: T3TaskNode) -> Bool {
        if lhs.status != rhs.status { return lhs.status < rhs.status }
        return (lhs.lastActivity ?? .distantPast) > (rhs.lastActivity ?? .distantPast)
    }

    private static func updatedFirst(_ lhs: T3Thread, _ rhs: T3Thread) -> Bool {
        (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
    }
}
