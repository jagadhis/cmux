import Foundation

/// Which thread's agent launched which thread: T3's handoffs.
///
/// An agent hands work off by starting a new top-level thread with
/// `t3_thread_launch` or `create_threads`. T3 records no parent on the new
/// thread (that's for sub-threads), so the only record is the launching
/// thread's tool call, whose result names the new thread. The index reads
/// those tool calls once, then only rows added since, so a refresh costs a
/// few milliseconds after the first read.
public struct T3LaunchIndex: Hashable, Sendable, Codable {
    /// The launching thread, by launched thread id.
    public private(set) var launcherByThreadId: [String: String] = [:]
    /// The last turn-item row read.
    var scannedThroughRowId: Int64 = 0
    /// Launch calls read before they finished, to read again.
    var unfinishedRowIds: Set<Int64> = []
    /// Whether the index has read T3's history since it last started over.
    public private(set) var hasScanned = false
    /// Bumped each time the index starts over, so a read from before doesn't replace it.
    var generation = 0
    /// T3's `compacted-at` marker when the index last read. Compaction can renumber rows.
    var compactionMarker: String?

    public init() {}

    /// Creates an index with known launches, for tests and previews.
    public init(launchers: [String: String]) {
        launcherByThreadId = launchers
        hasScanned = true
    }

    /// Whether this index has read further than `other`, so a slower read
    /// that started earlier doesn't replace a newer index.
    public func isAhead(of other: T3LaunchIndex) -> Bool {
        if generation != other.generation { return generation > other.generation }
        if hasScanned != other.hasScanned { return hasScanned }
        if scannedThroughRowId != other.scannedThroughRowId { return scannedThroughRowId > other.scannedThroughRowId }
        return launcherByThreadId.count > other.launcherByThreadId.count
            || (launcherByThreadId.count == other.launcherByThreadId.count && unfinishedRowIds.count < other.unfinishedRowIds.count)
    }

    /// The thread that launched `threadId`, if one did.
    public func launcher(of threadId: String) -> String? {
        launcherByThreadId[threadId]
    }

    /// Fills in `launchedByThreadId` from the index where T3 didn't record it.
    ///
    /// - Parameter threads: Threads as read from T3.
    /// - Returns: The threads with their launchers.
    public func applied(to threads: [T3Thread]) -> [T3Thread] {
        threads.map { thread in
            guard thread.launchedByThreadId == nil, let launcher = launcherByThreadId[thread.id], launcher != thread.id else {
                return thread
            }
            var thread = thread
            thread.launchedByThreadId = launcher
            return thread
        }
    }

    /// Records one tool-call row.
    ///
    /// - Parameters:
    ///   - rowId: The turn item's row id.
    ///   - threadId: The thread that made the call.
    ///   - toolName: The tool's name as the provider reported it, such as `mcp__t3-code__t3_thread_launch`.
    ///   - status: The call's status.
    ///   - output: The call's `output` object.
    mutating func record(rowId: Int64, threadId: String, toolName: String, status: String?, output: [String: Any]?) {
        guard Self.isLaunchTool(toolName) else {
            unfinishedRowIds.remove(rowId)
            return
        }
        let launched = output.map(Self.launchedThreadIds(output:)) ?? []
        if launched.isEmpty, Self.isInFlight(status) {
            unfinishedRowIds.insert(rowId)
        } else {
            unfinishedRowIds.remove(rowId)
        }
        for child in launched where child != threadId {
            launcherByThreadId[child] = threadId
        }
    }

    mutating func finishScan(through rowId: Int64) {
        scannedThroughRowId = max(scannedThroughRowId, rowId)
        hasScanned = true
    }

    /// Starts reading T3's history again, for when T3 compacted or rebuilt its
    /// database and row ids no longer line up. Known launches are kept: they
    /// name threads, not rows, so tasks stay grouped while the history is reread.
    mutating func reset() {
        scannedThroughRowId = 0
        unfinishedRowIds = []
        hasScanned = false
        generation += 1
    }

    /// Whether a tool call may still produce its result. Any other status
    /// (completed, failed, cancelled, interrupted…) is final.
    static func isInFlight(_ status: String?) -> Bool {
        guard let status else { return true }
        return ["pending", "running", "in_progress", "inProgress", "started", "queued", "waiting"].contains(status)
    }

    /// Whether a tool name is one of T3's thread-launching tools, under any provider's prefix.
    static func isLaunchTool(_ name: String) -> Bool {
        name.hasSuffix("t3_thread_launch") || name.hasSuffix("create_threads")
    }

    /// The thread ids a launch call's output names: `{threadId}` for
    /// `t3_thread_launch`, `{threads: [{threadId}]}` for `create_threads`,
    /// either as `structuredContent` or as JSON text in `content`.
    static func launchedThreadIds(output: [String: Any]) -> [String] {
        func ids(in object: [String: Any]) -> [String] {
            if let id = object["threadId"] as? String { return [id] }
            if let threads = object["threads"] as? [[String: Any]] {
                return threads.compactMap { $0["threadId"] as? String }
            }
            return []
        }
        if let structured = output["structuredContent"] as? [String: Any] {
            let found = ids(in: structured)
            if !found.isEmpty { return found }
        }
        if let content = output["content"] as? String,
           let data = content.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return ids(in: object)
        }
        return []
    }
}
