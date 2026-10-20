import Foundation

extension T3Thread {
    /// T3's record of the sub-agent behind a sub-thread.
    ///
    /// A provider's own sub-agent (Claude's Task tool, a Codex sub-agent) runs
    /// inside its parent's run, so its thread has no runs of its own: this
    /// record is the only place its state lives. A delegated task
    /// (`delegate_task`) has runs of its own, which take precedence.
    public struct Subagent: Hashable, Sendable {
        /// Who started it: `provider_native` or `app_owned`.
        public var origin: String
        /// Its status, such as `running`, `completed` or `failed`.
        public var status: String
        /// What it's doing now, as the provider reports it.
        public var progress: String?
        /// When it started.
        public var startedAt: Date?
        /// When it finished, if it has.
        public var completedAt: Date?

        /// Creates a sub-agent record.
        ///
        /// - Parameters:
        ///   - origin: Who started it.
        ///   - status: Its status.
        ///   - progress: What it's doing now.
        ///   - startedAt: When it started.
        ///   - completedAt: When it finished.
        public init(origin: String, status: String, progress: String? = nil, startedAt: Date? = nil, completedAt: Date? = nil) {
            self.origin = origin
            self.status = status
            self.progress = progress
            self.startedAt = startedAt
            self.completedAt = completedAt
        }

        /// Whether the provider started it itself, rather than T3 delegating it.
        public var isNative: Bool { origin == "provider_native" }

        /// Whether it's still working.
        public var isRunning: Bool { T3ThreadStatus.activeRunStatuses.contains(status) }
    }
}

/// A sub-thread in a task's outline, below the thread that started it.
public struct T3SubThreadRow: Identifiable, Hashable, Sendable {
    /// The sub-thread.
    public var thread: T3Thread
    /// The thread it's listed under: a main thread, or another sub-thread.
    public var parent: T3Thread?
    /// 1 for a sub-thread of a main thread, 2 for one of its sub-threads, and so on.
    public var depth: Int

    /// The sub-thread's id.
    public var id: String { thread.id }
}

/// A task's sub-threads, each listed under the thread that started it.
public struct T3SubThreadOutline: Hashable, Sendable {
    /// Rows by the main thread (the task's thread or a handoff) they're under, depth first.
    public var rowsByMainThreadId: [String: [T3SubThreadRow]]
    /// Finished sub-threads left out by the limit.
    public var hiddenCount: Int

    /// The sub-threads under a main thread, depth first.
    public func rows(under mainThreadId: String) -> [T3SubThreadRow] {
        rowsByMainThreadId[mainThreadId] ?? []
    }
}

extension T3TaskNode {
    /// The thread a sub-thread is listed under: its parent, else its lineage
    /// root, else the task's thread, whichever is in the task.
    public func listedParent(of subThread: T3Thread) -> T3Thread {
        for id in [subThread.parentThreadId, subThread.rootThreadId].compactMap({ $0 }) where id != subThread.id {
            if let parent = thread(withId: id) { return parent }
        }
        return thread
    }

    /// The task's sub-threads, each under the thread that started it.
    ///
    /// Under each thread, sub-threads with live work in them come first, then
    /// the newest; each is followed by its own sub-threads. Live sub-threads
    /// are always listed, with the finished parents that link them to a main
    /// thread; other finished ones fill in up to `finishedLimit`.
    ///
    /// - Parameter finishedLimit: How many other finished sub-threads to list.
    /// - Returns: The outline.
    public func subThreadOutline(finishedLimit: Int = .max) -> T3SubThreadOutline {
        let mains = mainThreads
        let mainIds = Set(mains.map(\.id))
        var children: [String: [T3Thread]] = [:]
        var parentId: [String: String] = [:]
        for sub in subThreads where !mainIds.contains(sub.id) {
            let parent = listedParent(of: sub).id
            parentId[sub.id] = parent
            children[parent, default: []].append(sub)
        }

        // Sub-threads that are live, or lead to one.
        var live: Set<String> = []
        for sub in subThreads where T3ThreadStatus.of(sub) < .done {
            var id: String? = sub.id
            var seen: Set<String> = []
            while let current = id, !mainIds.contains(current), seen.insert(current).inserted {
                live.insert(current)
                id = parentId[current]
            }
        }
        func order(_ lhs: T3Thread, _ rhs: T3Thread) -> Bool {
            let lhsLive = live.contains(lhs.id), rhsLive = live.contains(rhs.id)
            if lhsLive != rhsLive { return lhsLive }
            return (lhs.createdAt ?? lhs.updatedAt ?? .distantPast) > (rhs.createdAt ?? rhs.updatedAt ?? .distantPast)
        }

        var visited: Set<String> = []
        var finishedShown = 0
        var hidden = 0
        func walk(_ parent: T3Thread, depth: Int, into rows: inout [T3SubThreadRow]) {
            for child in (children[parent.id] ?? []).sorted(by: order) where visited.insert(child.id).inserted {
                let shown = live.contains(child.id) || finishedShown < finishedLimit
                guard shown else {
                    hidden += 1 + countBelow(child)
                    continue
                }
                if !live.contains(child.id) { finishedShown += 1 }
                rows.append(T3SubThreadRow(thread: child, parent: parent, depth: depth))
                walk(child, depth: depth + 1, into: &rows)
            }
        }
        func countBelow(_ thread: T3Thread) -> Int {
            (children[thread.id] ?? []).reduce(0) { count, child in
                visited.insert(child.id).inserted ? count + 1 + countBelow(child) : count
            }
        }

        var rowsByMain: [String: [T3SubThreadRow]] = [:]
        for main in mains {
            var rows: [T3SubThreadRow] = []
            walk(main, depth: 1, into: &rows)
            if !rows.isEmpty { rowsByMain[main.id] = rows }
        }
        // A parent cycle (bad data) never reaches a main thread: list what's left under the task's thread.
        let stranded = subThreads.filter { !visited.contains($0.id) && !mainIds.contains($0.id) }
        if !stranded.isEmpty {
            var rows = rowsByMain[thread.id] ?? []
            for sub in stranded.sorted(by: order) where visited.insert(sub.id).inserted {
                if live.contains(sub.id) || finishedShown < finishedLimit {
                    if !live.contains(sub.id) { finishedShown += 1 }
                    rows.append(T3SubThreadRow(thread: sub, parent: thread, depth: 1))
                } else {
                    hidden += 1
                }
            }
            rowsByMain[thread.id] = rows
        }
        return T3SubThreadOutline(rowsByMainThreadId: rowsByMain, hiddenCount: hidden)
    }
}
