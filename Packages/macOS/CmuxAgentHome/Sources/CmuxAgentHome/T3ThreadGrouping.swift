import Foundation

/// A T3 Code thread, as read from T3's local state database.
public struct T3Thread: Identifiable, Hashable, Sendable {
    /// A pull request linked to a thread.
    public struct PullRequest: Hashable, Sendable {
        /// The `owner/name` repository.
        public var repository: String
        /// The pull request number.
        public var number: Int
        /// The pull request URL.
        public var url: URL?
        /// The pull request title, when T3 has a snapshot.
        public var title: String?
        /// The state T3 last saw, such as `open` or `merged`.
        public var state: String?

        /// Creates a linked pull request.
        ///
        /// - Parameters:
        ///   - repository: The `owner/name` repository.
        ///   - number: The pull request number.
        ///   - url: The pull request URL.
        ///   - title: The pull request title.
        ///   - state: The state T3 last saw.
        public init(repository: String, number: Int, url: URL? = nil, title: String? = nil, state: String? = nil) {
            self.repository = repository
            self.number = number
            self.url = url
            self.title = title
            self.state = state
        }
    }

    /// The T3 thread id.
    public var id: String
    /// The T3 project id.
    public var projectId: String
    /// The T3 project title, or `nil` when the project is unknown.
    public var projectName: String?
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

    /// Creates a T3 thread.
    ///
    /// - Parameters:
    ///   - id: The T3 thread id.
    ///   - projectId: The T3 project id.
    ///   - projectName: The T3 project title.
    ///   - title: The thread title.
    ///   - branch: The branch the thread worked on.
    ///   - worktreePath: The worktree or directory the thread worked in.
    ///   - provider: The provider instance id.
    ///   - createdAt: When the thread was created.
    ///   - updatedAt: When the thread was last updated.
    ///   - pullRequests: Pull requests linked to the thread.
    public init(
        id: String,
        projectId: String,
        projectName: String?,
        title: String,
        branch: String? = nil,
        worktreePath: String? = nil,
        provider: String,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        pullRequests: [PullRequest] = []
    ) {
        self.id = id
        self.projectId = projectId
        self.projectName = projectName
        self.title = title
        self.branch = branch
        self.worktreePath = worktreePath
        self.provider = provider
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pullRequests = pullRequests
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

/// A task proposed from one or more T3 threads that worked on the same branch.
public struct T3TaskProposal: Identifiable, Hashable, Sendable {
    /// A stable id: the project id and branch.
    public var id: String
    /// The T3 project id.
    public var projectId: String
    /// The T3 project title.
    public var projectName: String
    /// The proposed task title.
    public var title: String
    /// The shared branch.
    public var branch: String
    /// The most recently used worktree, to open the task's workspace in.
    public var worktreePath: String?
    /// The threads, most recently updated first.
    public var threads: [T3Thread]
    /// The most recent pull request linked to any of the threads.
    public var pullRequest: T3Thread.PullRequest?

    /// When any of the threads was last updated.
    public var updatedAt: Date? { threads.compactMap(\.updatedAt).max() }
}

/// Threads that couldn't be grouped into a task.
public struct T3UnsortedThread: Identifiable, Hashable, Sendable {
    /// Why a thread wasn't grouped.
    public enum Reason: Sendable {
        /// The thread has no project, or is a T3 scratch thread.
        case noProject
        /// The thread worked on a default branch such as `main`, so its branch says nothing about its task.
        case defaultBranch
    }

    /// The thread.
    public var thread: T3Thread
    /// Why it wasn't grouped.
    public var reason: Reason

    /// The thread id.
    public var id: String { thread.id }
}

/// The result of grouping T3 threads.
public struct T3ThreadGroupingResult: Hashable, Sendable {
    /// Proposed tasks, most recently updated first.
    public var tasks: [T3TaskProposal]
    /// Threads left for the sorting flow, most recently updated first.
    public var unsorted: [T3UnsortedThread]
}

/// Groups T3 threads into proposed Agent Home tasks.
public enum T3ThreadGrouping {
    /// Branch names that don't identify a task on their own.
    public static let defaultBranchNames: Set<String> = ["main", "master", "develop", "dev", "trunk"]

    /// Groups threads by project and branch.
    ///
    /// Threads with no known project, with a worktree under `scratchDirectory`,
    /// or on a default branch go to ``T3ThreadGroupingResult/unsorted``.
    /// Every other thread joins the task for its project and branch.
    ///
    /// - Parameters:
    ///   - threads: The threads to group. Archived and deleted threads should be left out by the caller.
    ///   - scratchDirectory: T3's scratch directory, usually `~/.t3/scratch`.
    /// - Returns: Proposed tasks and the threads left unsorted.
    public static func group(_ threads: [T3Thread], scratchDirectory: String? = nil) -> T3ThreadGroupingResult {
        var unsorted: [T3UnsortedThread] = []
        var buckets: [String: [T3Thread]] = [:]
        var bucketOrder: [String] = []

        for thread in threads {
            let isScratch = scratchDirectory.map { dir in thread.worktreePath?.hasPrefix(dir) == true } ?? false
            guard thread.projectName?.isEmpty == false, !isScratch else {
                unsorted.append(T3UnsortedThread(thread: thread, reason: .noProject))
                continue
            }
            guard let branch = thread.branch?.trimmingCharacters(in: .whitespaces), !branch.isEmpty,
                  !defaultBranchNames.contains(branch.lowercased())
            else {
                unsorted.append(T3UnsortedThread(thread: thread, reason: .defaultBranch))
                continue
            }
            let key = thread.projectId + "\u{1F}" + branch
            if buckets[key] == nil { bucketOrder.append(key) }
            buckets[key, default: []].append(thread)
        }

        let tasks = bucketOrder.compactMap { key -> T3TaskProposal? in
            guard let members = buckets[key], let first = members.first, let branch = first.branch else { return nil }
            let sorted = members.sorted(by: updatedFirst)
            let pullRequest = sorted.lazy.compactMap { $0.pullRequests.max(by: { $0.number < $1.number }) }.first
            return T3TaskProposal(
                id: key,
                projectId: first.projectId,
                projectName: first.projectName ?? "",
                title: title(for: sorted, branch: branch),
                branch: branch,
                worktreePath: sorted.lazy.compactMap(\.worktreePath).first,
                threads: sorted,
                pullRequest: pullRequest
            )
        }

        return T3ThreadGroupingResult(
            tasks: tasks.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) },
            unsorted: unsorted.sorted { updatedFirst($0.thread, $1.thread) }
        )
    }

    /// The proposed title: a lone thread keeps its own title; a group is named after its branch.
    static func title(for threads: [T3Thread], branch: String) -> String {
        if threads.count == 1, let only = threads.first, !only.title.isEmpty { return only.title }
        return humanize(branch: branch)
    }

    /// Turns a branch such as `feat/voice-bulbul-v4-flash` into `Voice bulbul v4 flash`.
    static func humanize(branch: String) -> String {
        let lastSegment = branch.split(separator: "/").last.map(String.init) ?? branch
        let words = lastSegment
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map { word -> String in
                let lower = word.lowercased()
                return acronyms.contains(lower) ? lower.uppercased() : lower
            }
        guard var first = words.first else { return branch }
        if first == first.lowercased() { first = first.prefix(1).uppercased() + first.dropFirst() }
        return ([first] + words.dropFirst()).joined(separator: " ")
    }

    static let acronyms: Set<String> = ["ai", "api", "ci", "cli", "db", "mcp", "pr", "sdk", "seo", "sso", "ui", "url", "ux"]

    private static func updatedFirst(_ lhs: T3Thread, _ rhs: T3Thread) -> Bool {
        (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
    }
}
