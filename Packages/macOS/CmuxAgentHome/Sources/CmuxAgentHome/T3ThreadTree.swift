import Foundation

/// A T3 thread's state as Agent Home shows it.
public enum T3ThreadStatus: Int, Sendable, Comparable {
    /// The thread's agent is waiting on the user.
    case needsYou
    /// The thread's agent is working.
    case running
    /// The agent finished and the user hasn't verified the result (settled the thread) yet.
    case done
    /// Nothing to do: settled, or a sub-thread with no runs of its own.
    case idle

    public static func < (lhs: T3ThreadStatus, rhs: T3ThreadStatus) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Run statuses that mean the agent is still going.
    public static let activeRunStatuses: Set<String> = ["preparing", "queued", "starting", "running", "waiting"]

    /// The status of one thread. A pending request only counts while a run is
    /// active, so a stale request on a finished thread doesn't raise "needs you".
    /// A finished thread is done until the user settles it.
    ///
    /// - Parameter thread: The thread.
    /// - Returns: Its status.
    public static func of(_ thread: T3Thread) -> T3ThreadStatus {
        guard let run = thread.latestRunStatus else { return .idle }
        if activeRunStatuses.contains(run) {
            return thread.hasPendingRequest || run == "waiting" ? .needsYou : .running
        }
        return thread.isSettled ? .idle : .done
    }
}

/// A task: a thread the user started, with the threads its agents handed work
/// off to and every sub-thread they created under it.
public struct T3TaskNode: Identifiable, Hashable, Sendable {
    /// The thread the user started: the top of the handoff chain.
    public var thread: T3Thread
    /// Threads an agent in this task started as new top-level threads
    /// (`t3_thread_launch`, `create_threads`), oldest first, so the chain reads top down.
    public var handoffs: [T3Thread]
    /// Sub-threads anywhere below the main thread or its handoffs, most recently updated first.
    public var subThreads: [T3Thread]

    /// Creates a task.
    ///
    /// - Parameters:
    ///   - thread: The thread the user started.
    ///   - handoffs: Threads handed off to, oldest first.
    ///   - subThreads: Sub-threads below it.
    public init(thread: T3Thread, handoffs: [T3Thread] = [], subThreads: [T3Thread] = []) {
        self.thread = thread
        self.handoffs = handoffs
        self.subThreads = subThreads
    }

    /// The task id: the root thread's id.
    public var id: String { thread.id }

    /// The main thread, then its handoffs, then sub-threads.
    public var allThreads: [T3Thread] { [thread] + handoffs + subThreads }

    /// The main thread and its handoffs: the threads the user verifies.
    public var mainThreads: [T3Thread] { [thread] + handoffs }

    /// The thread with `id`, if it's part of the task.
    public func thread(withId id: String) -> T3Thread? {
        allThreads.first { $0.id == id }
    }

    /// The most urgent status of every thread in the task.
    public var status: T3ThreadStatus {
        allThreads.map(T3ThreadStatus.of).min() ?? .idle
    }

    /// Sub-threads that are running or waiting on the user.
    public var liveSubThreadCount: Int {
        subThreads.filter { T3ThreadStatus.of($0) < .done }.count
    }

    /// Whether the task finished since the user last looked at it.
    public var hasUnseenResult: Bool {
        status == .done && mainThreads.contains(where: \.hasUnseenResult)
    }

    /// Whether the main thread or its latest handoff stopped before finishing.
    public var latestRunEndedEarly: Bool {
        (handoffs.last ?? thread).latestRunEndedEarly
    }

    /// When any thread in the task last changed.
    public var lastActivity: Date? {
        allThreads.compactMap(\.updatedAt).max()
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

    /// Creates a project node.
    ///
    /// - Parameters:
    ///   - id: The T3 project id, or an empty string for threads without a project.
    ///   - name: The project name.
    ///   - root: The project's root directory.
    ///   - recentTasks: Recent tasks, most recent first.
    ///   - olderTasks: Older tasks, most recent first.
    public init(id: String, name: String, root: String?, recentTasks: [T3TaskNode], olderTasks: [T3TaskNode]) {
        self.id = id
        self.name = name
        self.root = root
        self.recentTasks = recentTasks
        self.olderTasks = olderTasks
    }

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
    /// A thread an agent launched (``T3Thread/launchedByThreadId``) is a
    /// handoff: it joins the task of the thread that launched it, and so does
    /// everything below it, so a chain of handoffs groups under the thread the
    /// user started. A launcher that isn't among `threads` leaves the handoff a
    /// task of its own.
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

        // The top of a thread's own lineage (sub-threads and forks).
        func lineageRoot(of thread: T3Thread) -> T3Thread {
            if let root = thread.rootThreadId, root != thread.id, let present = byId[root] { return present }
            var current = thread
            var seen: Set<String> = [thread.id]
            while let parent = current.parentThreadId, let next = byId[parent], seen.insert(parent).inserted {
                current = next
            }
            return current
        }

        // The task a thread belongs to: its lineage root, then up the handoff chain.
        func taskRoot(of thread: T3Thread) -> String {
            var current = lineageRoot(of: thread)
            var path = [current.id]
            while let launcher = current.launchedByThreadId, let next = byId[launcher] {
                let root = lineageRoot(of: next)
                if let repeatIndex = path.firstIndex(of: root.id) {
                    // A cycle (bad data): every thread on it picks the same root.
                    return path[repeatIndex...].min() ?? root.id
                }
                path.append(root.id)
                current = root
            }
            return current.id
        }

        var members: [String: (handoffs: [T3Thread], subThreads: [T3Thread])] = [:]
        var roots: [T3Thread] = []
        for thread in threads {
            let root = taskRoot(of: thread)
            if root == thread.id {
                roots.append(thread)
            } else if lineageRoot(of: thread).id == thread.id {
                members[root, default: ([], [])].handoffs.append(thread)
            } else {
                members[root, default: ([], [])].subThreads.append(thread)
            }
        }

        let tasks = roots.map { root in
            let group = members[root.id] ?? ([], [])
            return T3TaskNode(
                thread: root,
                handoffs: group.handoffs.sorted(by: createdFirst),
                subThreads: group.subThreads.sorted(by: updatedFirst)
            )
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

    /// The launchers of handed-off threads that aren't among `threads`, up the
    /// chain as far as `index` knows, so a settled thread that handed off still
    /// heads its task. Read them with ``T3CodeStateReader/activeThreads(openTaskIds:includingThreadIds:)``.
    ///
    /// - Parameters:
    ///   - threads: Threads as read, with launchers applied.
    ///   - index: Known launches.
    /// - Returns: Thread ids to read as well.
    public static func missingLaunchers(of threads: [T3Thread], index: T3LaunchIndex) -> Set<String> {
        let present = Set(threads.map(\.id))
        var missing: Set<String> = []
        for thread in threads {
            var launcher = thread.launchedByThreadId
            var seen: Set<String> = [thread.id]
            while let id = launcher, seen.insert(id).inserted {
                if !present.contains(id) { missing.insert(id) }
                launcher = index.launcher(of: id)
            }
        }
        return missing
    }

    /// Live tasks first (needs you, then running), then most recent activity.
    static func taskOrder(_ lhs: T3TaskNode, _ rhs: T3TaskNode) -> Bool {
        if lhs.status != rhs.status { return lhs.status < rhs.status }
        return (lhs.lastActivity ?? .distantPast) > (rhs.lastActivity ?? .distantPast)
    }

    private static func createdFirst(_ lhs: T3Thread, _ rhs: T3Thread) -> Bool {
        (lhs.createdAt ?? lhs.updatedAt ?? .distantPast) < (rhs.createdAt ?? rhs.updatedAt ?? .distantPast)
    }

    private static func updatedFirst(_ lhs: T3Thread, _ rhs: T3Thread) -> Bool {
        (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
    }
}
