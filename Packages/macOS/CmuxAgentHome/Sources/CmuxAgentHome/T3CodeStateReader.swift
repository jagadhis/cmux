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
    /// with a live run or a pending request are always read, and so is every
    /// thread of a task in `openTaskIds`, so a task open in cmux stays readable
    /// after it's settled.
    ///
    /// - Parameter openTaskIds: Root thread ids of tasks open in cmux.
    /// - Returns: The threads, most recently updated first.
    /// - Throws: ``ReadError`` when the database can't be opened or queried.
    public func activeThreads(openTaskIds: Set<String> = []) throws -> [T3Thread] {
        let db = try open()
        defer { sqlite3_close_v2(db) }

        let pullRequests = try readPullRequests(db)
        let openIds = openTaskIds.sorted()
        let openList = openIds.isEmpty ? "NULL" : Array(repeating: "?", count: openIds.count).joined(separator: ", ")
        let sql = """
            WITH latest_run AS (
                SELECT r.thread_id, r.status, r.completed_at
                FROM orchestration_v2_projection_runs r
                WHERE r.ordinal = (SELECT max(ordinal) FROM orchestration_v2_projection_runs WHERE thread_id = r.thread_id)
            )
            SELECT t.thread_id, t.project_id, p.title, t.title, t.default_provider,
                   t.created_at, t.updated_at, t.payload_json, p.workspace_root,
                   lr.status,
                   (SELECT count(*) FROM orchestration_v2_projection_runtime_requests q
                     WHERE q.thread_id = t.thread_id AND q.status = 'pending'),
                   lr.completed_at,
                   json_extract(coalesce(root.payload_json, t.payload_json), '$.settledOverride') = 'settled'
            FROM orchestration_v2_projection_threads t
            LEFT JOIN projection_projects p ON p.project_id = t.project_id AND p.deleted_at IS NULL
            LEFT JOIN orchestration_v2_projection_threads root
                   ON root.thread_id = json_extract(t.payload_json, '$.lineage.rootThreadId')
                  AND root.thread_id <> t.thread_id
            LEFT JOIN latest_run lr ON lr.thread_id = t.thread_id
            WHERE t.archived_at IS NULL AND t.deleted_at IS NULL
              AND (
                (coalesce(json_extract(coalesce(root.payload_json, t.payload_json), '$.settledOverride'), '') <> 'settled'
                  AND coalesce(julianday(json_extract(coalesce(root.payload_json, t.payload_json), '$.snoozedUntil')), 0) <= julianday('now'))
                OR lr.status IN ('preparing', 'queued', 'starting', 'running', 'waiting')
                OR EXISTS (SELECT 1 FROM orchestration_v2_projection_runtime_requests q
                            WHERE q.thread_id = t.thread_id AND q.status = 'pending')
                OR coalesce(json_extract(t.payload_json, '$.lineage.rootThreadId'), t.thread_id) IN (\(openList))
              )
            ORDER BY t.updated_at DESC
            """
        return try query(db, sql, bind: openIds) { row in
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
                pullRequests: pullRequests[id] ?? [],
                parentThreadId: lineage?["parentThreadId"] as? String,
                rootThreadId: lineage?["rootThreadId"] as? String,
                relationshipToParent: lineage?["relationshipToParent"] as? String,
                latestRunStatus: row.text(9),
                hasPendingRequest: row.int(10) > 0,
                latestRunCompletedAt: Self.date(row.text(11)),
                lastVisitedAt: Self.date(payload["lastVisitedAt"] as? String),
                isSettled: row.int(12) == 1
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

    /// T3 threads linked to pull requests, keyed by `owner/name#number`, most recently updated thread first.
    /// Settled threads count; archived and deleted ones don't.
    public func pullRequestThreads() throws -> [String: PullRequestThread] {
        let db = try open()
        defer { sqlite3_close_v2(db) }
        let sql = """
            SELECT pr.repository, pr.number, t.thread_id, t.title,
                   coalesce(json_extract(t.payload_json, '$.lineage.rootThreadId'), t.thread_id)
            FROM projection_thread_pull_requests pr
            JOIN orchestration_v2_projection_threads t ON t.thread_id = pr.thread_id
            WHERE t.archived_at IS NULL AND t.deleted_at IS NULL
            ORDER BY t.updated_at ASC
            """
        let rows: [(String, PullRequestThread)] = try query(db, sql) { row in
            ("\(row.text(0) ?? "")#\(row.int(1))", PullRequestThread(threadId: row.text(2) ?? "", title: row.text(3) ?? "", taskId: row.text(4) ?? ""))
        }
        // Later rows are newer, so they win.
        return Dictionary(rows, uniquingKeysWith: { _, newer in newer })
    }

    private func readPullRequests(_ db: OpaquePointer) throws -> [String: [T3Thread.PullRequest]] {
        let sql = "SELECT thread_id, repository, number, url, snapshot_json FROM projection_thread_pull_requests"
        let rows: [(String, T3Thread.PullRequest)] = try query(db, sql) { row in
            let snapshot = Self.jsonObject(row.text(4))
            let pullRequest = T3Thread.PullRequest(
                repository: row.text(1) ?? "",
                number: row.int(2),
                url: row.text(3).flatMap(URL.init(string:)),
                title: snapshot["title"] as? String,
                state: snapshot["state"] as? String
            )
            return (row.text(0) ?? "", pullRequest)
        }
        return Dictionary(grouping: rows, by: \.0).mapValues { $0.map(\.1) }
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
        guard let text else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
