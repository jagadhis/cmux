import Foundation
import SQLite3

/// Reads threads from T3 Code's local state database, read-only.
///
/// T3 Code keeps its state in `~/.t3/userdata/statev2.sqlite`. The reader
/// opens it with `SQLITE_OPEN_READONLY` and never writes, so it is safe to
/// run while T3 Code is open.
public struct T3CodeStateReader: Sendable {
    /// Errors from reading the database.
    public enum ReadError: Error, Equatable {
        /// The database couldn't be opened.
        case open(String)
        /// A query failed.
        case query(String)
    }

    /// The database file.
    public var databaseURL: URL

    /// The default database location, `~/.t3/userdata/statev2.sqlite`.
    public static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".t3/userdata/statev2.sqlite")
    }

    /// Creates a reader.
    ///
    /// - Parameter databaseURL: The database file. Defaults to ``defaultDatabaseURL``.
    public init(databaseURL: URL = T3CodeStateReader.defaultDatabaseURL) {
        self.databaseURL = databaseURL
    }

    /// Reads the threads Agent Home lists: those that aren't archived, deleted,
    /// settled or snoozed.
    ///
    /// A thread counts as settled when its task's root thread is: settling a
    /// task in T3 settles the sub-threads its agents created with it. Threads
    /// with a live run, a working sub-agent or a pending request are always
    /// read, and so is every thread of a task in `openTaskIds`, so a task open
    /// in cmux stays readable after it's settled.
    ///
    /// - Parameters:
    ///   - openTaskIds: Root thread ids of tasks open in cmux.
    ///   - includingThreadIds: Threads to read even when settled, such as the
    ///     thread a listed thread was handed off from, so the handoff stays grouped.
    /// - Returns: The threads, most recently updated first.
    /// - Throws: ``ReadError`` when the database can't be opened or queried.
    public func activeThreads(openTaskIds: Set<String> = [], includingThreadIds: Set<String> = []) throws -> [T3Thread] {
        let db = try open()
        defer { sqlite3_close_v2(db) }

        let openIds = openTaskIds.sorted()
        let openList = openIds.isEmpty ? "NULL" : Array(repeating: "?", count: openIds.count).joined(separator: ", ")
        let includedIds = includingThreadIds.sorted()
        let includedList = includedIds.isEmpty ? "NULL" : Array(repeating: "?", count: includedIds.count).joined(separator: ", ")
        // Older T3 versions have no sub-agent table; read their threads without it.
        let subagents = try hasTable(db, "orchestration_v2_projection_subagents")
            ? """
                SELECT child_thread_id, origin, status, json_extract(payload_json, '$.progress') AS progress, started_at, completed_at
                FROM (SELECT *, row_number() OVER (PARTITION BY child_thread_id ORDER BY updated_at DESC, rowid DESC) AS n
                      FROM orchestration_v2_projection_subagents WHERE child_thread_id IS NOT NULL)
                WHERE n = 1
                """
            : "SELECT NULL AS child_thread_id, NULL AS origin, NULL AS status, NULL AS progress, NULL AS started_at, NULL AS completed_at WHERE 0"
        let sql = """
            WITH latest_run AS (
                SELECT r.thread_id, r.status, r.completed_at
                FROM orchestration_v2_projection_runs r
                WHERE r.ordinal = (SELECT max(ordinal) FROM orchestration_v2_projection_runs WHERE thread_id = r.thread_id)
            ),
            subagent AS (\(subagents))
            SELECT t.thread_id, t.project_id, p.title, t.title, t.default_provider,
                   t.created_at, t.updated_at, t.payload_json, p.workspace_root,
                   lr.status,
                   (SELECT count(*) FROM orchestration_v2_projection_runtime_requests q
                     WHERE q.thread_id = t.thread_id AND q.status = 'pending'),
                   lr.completed_at,
                   json_extract(coalesce(root.payload_json, t.payload_json), '$.settledOverride') = 'settled',
                   sa.origin, sa.status, sa.progress, sa.started_at, sa.completed_at
            FROM orchestration_v2_projection_threads t
            LEFT JOIN projection_projects p ON p.project_id = t.project_id AND p.deleted_at IS NULL
            LEFT JOIN orchestration_v2_projection_threads root
                   ON root.thread_id = json_extract(t.payload_json, '$.lineage.rootThreadId')
                  AND root.thread_id <> t.thread_id
            LEFT JOIN latest_run lr ON lr.thread_id = t.thread_id
            LEFT JOIN subagent sa ON sa.child_thread_id = t.thread_id
            WHERE t.archived_at IS NULL AND t.deleted_at IS NULL
              AND (
                (coalesce(json_extract(coalesce(root.payload_json, t.payload_json), '$.settledOverride'), '') <> 'settled'
                  AND coalesce(julianday(json_extract(coalesce(root.payload_json, t.payload_json), '$.snoozedUntil')), 0) <= julianday('now'))
                OR lr.status IN ('preparing', 'queued', 'starting', 'running', 'waiting')
                OR sa.status IN ('preparing', 'queued', 'starting', 'running', 'waiting')
                OR EXISTS (SELECT 1 FROM orchestration_v2_projection_runtime_requests q
                            WHERE q.thread_id = t.thread_id AND q.status = 'pending')
                OR coalesce(json_extract(t.payload_json, '$.lineage.rootThreadId'), t.thread_id) IN (\(openList))
                OR t.thread_id IN (\(includedList))
              )
            ORDER BY t.updated_at DESC
            """
        return try query(db, sql, bind: openIds + includedIds) { row in
            let payload = Self.jsonObject(row.text(7))
            let lineage = payload["lineage"] as? [String: Any]
            let id = row.text(0) ?? ""
            return T3Thread(
                id: id,
                projectId: row.text(1) ?? "",
                projectName: row.text(2),
                projectRoot: row.text(8),
                title: row.text(3) ?? "",
                branch: payload["branch"] as? String,
                worktreePath: payload["worktreePath"] as? String,
                provider: (payload["providerInstanceId"] as? String) ?? row.text(4) ?? "",
                createdAt: Self.date(row.text(5)),
                updatedAt: Self.date(row.text(6)),
                pullRequests: (payload["pullRequests"] as? [[String: Any]] ?? []).compactMap(T3Thread.PullRequest.fromPayload),
                parentThreadId: lineage?["parentThreadId"] as? String,
                rootThreadId: lineage?["rootThreadId"] as? String,
                relationshipToParent: lineage?["relationshipToParent"] as? String,
                launchedByThreadId: lineage?["launchedByThreadId"] as? String,
                latestRunStatus: row.text(9),
                hasPendingRequest: row.int(10) > 0,
                latestRunCompletedAt: Self.date(row.text(11)),
                lastVisitedAt: Self.date(payload["lastVisitedAt"] as? String),
                isSettled: row.int(12) == 1,
                subagent: row.text(14).map { status in
                    T3Thread.Subagent(
                        origin: row.text(13) ?? "",
                        status: status,
                        progress: row.text(15).flatMap { $0.isEmpty ? nil : $0 },
                        startedAt: Self.date(row.text(16)),
                        completedAt: Self.date(row.text(17))
                    )
                }
            )
        }
    }

    /// A T3 project.
    public struct Project: Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var root: String

        public init(id: String, name: String, root: String) {
            self.id = id
            self.name = name
            self.root = root
        }
    }

    /// Every T3 project that isn't deleted, by name. New chats can start in any of them,
    /// including ones whose threads are all settled.
    public func projects() throws -> [Project] {
        let db = try open()
        defer { sqlite3_close_v2(db) }
        let sql = "SELECT project_id, title, workspace_root FROM projection_projects WHERE deleted_at IS NULL ORDER BY title COLLATE NOCASE"
        return try query(db, sql) { row in
            Project(id: row.text(0) ?? "", name: row.text(1) ?? "", root: row.text(2) ?? "")
        }
    }

    /// A T3 thread linked to a pull request.
    public struct PullRequestThread: Hashable, Sendable {
        /// The linked thread.
        public var threadId: String
        public var title: String
        /// The task it belongs to: its lineage root, or itself.
        public var taskId: String

        public init(threadId: String, title: String, taskId: String) {
            self.threadId = threadId
            self.title = title
            self.taskId = taskId
        }
    }

    /// T3 threads linked to pull requests, keyed by lowercased `owner/name#number`, most recently updated thread first.
    /// Settled threads count; archived and deleted ones don't.
    public func pullRequestThreads() throws -> [String: PullRequestThread] {
        let db = try open()
        defer { sqlite3_close_v2(db) }
        let sql = """
            SELECT json_extract(pr.value, '$.repository'), json_extract(pr.value, '$.number'), t.thread_id, t.title,
                   coalesce(json_extract(t.payload_json, '$.lineage.rootThreadId'), t.thread_id)
            FROM orchestration_v2_projection_threads t, json_each(t.payload_json, '$.pullRequests') pr
            WHERE t.archived_at IS NULL AND t.deleted_at IS NULL
              AND json_valid(t.payload_json)
              AND coalesce(json_extract(pr.value, '$.source'), '') <> 'stack-dismissed'
            ORDER BY t.updated_at ASC
            """
        let rows: [(String, PullRequestThread)] = try query(db, sql) { row in
            ("\((row.text(0) ?? "").lowercased())#\(row.int(1))", PullRequestThread(threadId: row.text(2) ?? "", title: row.text(3) ?? "", taskId: row.text(4) ?? ""))
        }
        // Later rows are newer, so they win.
        return Dictionary(rows, uniquingKeysWith: { _, newer in newer })
    }

    /// The files each thread's agent wrote, from T3's completed file changes.
    ///
    /// These include files outside the project, such as working-memory notes,
    /// which the project's git status doesn't show. Relative paths resolve
    /// against the thread's worktree, or its project's folder.
    ///
    /// - Parameter threadIds: The threads to read.
    /// - Returns: Each thread's files, most recently edited first, by thread id.
    ///   Threads that wrote nothing are absent.
    /// - Throws: ``ReadError`` when the database can't be opened or queried.
    public func sessionFiles(threadIds: [String]) throws -> [String: [AgentSessionFile]] {
        guard !threadIds.isEmpty else { return [:] }
        let db = try open()
        defer { sqlite3_close_v2(db) }
        let ids = Array(Set(threadIds)).sorted()
        let list = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let sql = """
            SELECT i.thread_id, json_extract(i.payload_json, '$.fileName'), count(*),
                   max(coalesce(json_extract(i.payload_json, '$.completedAt'), i.updated_at)),
                   coalesce(json_extract(t.payload_json, '$.worktreePath'), p.workspace_root)
            FROM orchestration_v2_projection_turn_items i
            JOIN orchestration_v2_projection_threads t ON t.thread_id = i.thread_id
            LEFT JOIN projection_projects p ON p.project_id = t.project_id
            WHERE i.thread_id IN (\(list))
              AND i.type = 'file_change' AND i.status = 'completed'
              AND coalesce(json_extract(i.payload_json, '$.fileName'), '') <> ''
            GROUP BY i.thread_id, json_extract(i.payload_json, '$.fileName')
            """
        let rows: [(String, AgentSessionFile)?] = try query(db, sql, bind: ids) { row in
            guard let threadId = row.text(0),
                  let path = AgentSessionFile.absolutePath(row.text(1) ?? "", relativeTo: row.text(4))
            else { return nil }
            return (threadId, AgentSessionFile(path: path, editCount: row.int(2), lastEditedAt: Self.date(row.text(3))))
        }
        // A relative and an absolute name can resolve to the same file.
        return Dictionary(grouping: rows.compactMap { $0 }, by: \.0)
            .mapValues { AgentSessionFile.merged([$0.map(\.1)]) }
    }

    /// Reads thread launches (handoffs) added since the index last looked.
    ///
    /// The first call reads every launch call in T3's history (a second or
    /// two on a large database); later calls read only new rows, plus calls
    /// that hadn't finished last time.
    ///
    /// When T3 has compacted or rebuilt its database since the last read, row
    /// ids may have changed, so the history is read again. With `allowsFullRead`
    /// off, the index is only marked for that, so a caller can do the slow read
    /// in the background (the index keeps its known launches meanwhile).
    ///
    /// - Parameters:
    ///   - index: The index to bring up to date.
    ///   - allowsFullRead: Whether to read the whole history now when needed.
    /// - Throws: ``ReadError`` when the database can't be opened or queried.
    public func updateLaunchIndex(_ index: inout T3LaunchIndex, allowsFullRead: Bool = true) throws {
        let db = try open()
        defer { sqlite3_close_v2(db) }

        let marker = (try? String(contentsOf: compactionMarkerURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxRowId = try query(db, "SELECT coalesce(max(rowid), 0) FROM orchestration_v2_projection_turn_items") { Int64($0.int(0)) }.first ?? 0
        // Compaction can renumber rows; fewer rows than last time means a rebuild.
        if index.hasScanned, marker != index.compactionMarker || maxRowId < index.scannedThroughRowId {
            index.reset()
        }
        if !index.hasScanned, !allowsFullRead { return }
        index.compactionMarker = marker

        let unfinished = index.unfinishedRowIds.sorted().map(String.init)
        let unfinishedList = unfinished.isEmpty ? "NULL" : unfinished.joined(separator: ", ")
        let sql = """
            SELECT rowid, thread_id, json_extract(payload_json, '$.toolName'), json_extract(payload_json, '$.status'),
                   json_extract(payload_json, '$.output')
            FROM orchestration_v2_projection_turn_items
            WHERE (rowid > \(index.scannedThroughRowId) OR rowid IN (\(unfinishedList)))
              AND type = 'dynamic_tool'
              AND (payload_json LIKE '%t3_thread_launch%' OR payload_json LIKE '%create_threads%')
            """
        let rows = try query(db, sql) { row in
            (Int64(row.int(0)), row.text(1) ?? "", row.text(2) ?? "", row.text(3), row.text(4))
        }
        for (rowId, threadId, toolName, status, output) in rows {
            let outputObject = output.map { Self.jsonObject($0) }
            index.record(rowId: rowId, threadId: threadId, toolName: toolName, status: status, output: outputObject)
        }
        index.finishScan(through: maxRowId)
    }

    /// T3 rewrites `compacted-at` next to its database when it compacts it.
    var compactionMarkerURL: URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent("compacted-at")
    }

    private func hasTable(_ db: OpaquePointer, _ name: String) throws -> Bool {
        try !query(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", bind: [name]) { _ in true }.isEmpty
    }

    private func open() throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(databaseURL.path, &db, flags, nil)
        guard status == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "status \(status)"
            if let db { sqlite3_close_v2(db) }
            throw ReadError.open(message)
        }
        sqlite3_busy_timeout(db, 2_000)
        return db
    }

    private func query<T>(_ db: OpaquePointer, _ sql: String, bind values: [String] = [], _ map: (Row) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ReadError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        var results: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ReadError.query(String(cString: sqlite3_errmsg(db))) }
            results.append(map(Row(statement: statement)))
        }
        return results
    }

    private struct Row {
        let statement: OpaquePointer

        func text(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }

        func int(_ column: Int32) -> Int {
            Int(sqlite3_column_int64(statement, column))
        }
    }

    static func jsonObject(_ text: String?) -> [String: Any] {
        guard let data = text?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    static func date(_ text: String?) -> Date? {
        T3Dates.parse(text)
    }
}
