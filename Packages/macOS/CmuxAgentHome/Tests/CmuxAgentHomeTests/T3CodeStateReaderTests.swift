import Foundation
import SQLite3
import Testing
@testable import CmuxAgentHome

@Suite struct T3CodeStateReaderTests {
    /// Builds a throwaway database with the columns the reader uses from T3's schema.
    func makeDatabase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("t3-state-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, title TEXT NOT NULL, workspace_root TEXT NOT NULL, deleted_at TEXT);
            CREATE TABLE orchestration_v2_projection_threads (
              thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL,
              default_provider TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
              archived_at TEXT, deleted_at TEXT, payload_json TEXT NOT NULL);
            CREATE TABLE orchestration_v2_projection_runs (
              run_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, ordinal INTEGER NOT NULL, status TEXT NOT NULL, completed_at TEXT);
            CREATE TABLE orchestration_v2_projection_runtime_requests (
              runtime_request_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, status TEXT NOT NULL);
            INSERT INTO orchestration_v2_projection_runs VALUES ('r1', 't1', 1, 'completed', '2026-10-18T11:00:00Z'), ('r2', 't1', 2, 'running', NULL),
              ('r5', 't5', 1, 'completed', '2026-10-18T12:00:00Z'), ('r7', 't7', 1, 'running', NULL), ('r9', 't9', 1, 'completed', '2026-10-19T08:00:00.250Z');
            INSERT INTO orchestration_v2_projection_runtime_requests VALUES ('q1', 't1', 'pending'), ('q2', 't2', 'resolved');
            CREATE TABLE projection_thread_pull_requests (
              thread_id TEXT NOT NULL, host TEXT NOT NULL, repository TEXT NOT NULL, number INTEGER NOT NULL,
              url TEXT NOT NULL, source TEXT NOT NULL, linked_at TEXT NOT NULL, snapshot_json TEXT);
            INSERT INTO projection_projects VALUES ('p1', 'oorva-app', '/Users/jags/projects/oorva-app', NULL), ('p2', 'gone', '/tmp/gone', '2026-10-01T00:00:00Z');
            INSERT INTO orchestration_v2_projection_threads VALUES
              ('t1', 'p1', 'Voice Relay Production Deployment', 'claudeAgent', '2026-10-18T10:00:00.000Z', '2026-10-19T03:12:00.500Z', NULL, NULL,
               '{"branch":"feat/voice-bulbul-v4-flash","worktreePath":"/Users/jags/projects/oorva-app","providerInstanceId":"claudeAgent_4","pullRequests":[{"host":"github.com","repository":"jagadhis/oorva-app","number":188,"url":"https://github.com/jagadhis/oorva-app/pull/188","source":"agent","linkedAt":"2026-10-19T03:00:00Z","snapshot":{"state":"open","title":"Voice relay on Bulbul v4 Flash","headBranch":"feat/voice-bulbul-v4-flash","baseBranch":"main","isDraft":false,"author":{"login":"jagadhis"},"additions":120,"deletions":8,"checksState":"failing","reviewDecision":"review-required","mergeability":"mergeable","syncedAt":"2026-10-19T03:10:00Z"},"stack":null},{"host":"github.com","repository":"jagadhis/oorva-app","number":150,"url":"https://github.com/jagadhis/oorva-app/pull/150","source":"stack-dismissed","linkedAt":"2026-10-19T03:00:00Z","snapshot":null,"stack":null}]}'),
              ('t2', 'p2', 'In a deleted project', 'codex', '2026-10-17T10:00:00Z', '2026-10-17T11:00:00Z', NULL, NULL,
               '{"lineage":{"parentThreadId":"t1","rootThreadId":"t1","relationshipToParent":"subagent"}}'),
              ('t3', 'p1', 'Archived', 'claudeAgent', '2026-10-17T10:00:00Z', '2026-10-19T09:00:00Z', '2026-10-19T09:00:00Z', NULL, '{}'),
              ('t4', 'p1', 'Deleted', 'claudeAgent', '2026-10-17T10:00:00Z', '2026-10-19T09:00:00Z', NULL, '2026-10-19T09:00:00Z', '{}'),
              ('t5', 'p1', 'Settled task', 'claudeAgent', '2026-10-17T10:00:00Z', '2026-10-18T12:00:00Z', NULL, NULL, '{"settledOverride":"settled"}'),
              ('t6', 'p1', 'Sub-thread of a settled task', 'claudeAgent', '2026-10-17T10:00:00Z', '2026-10-18T12:00:00Z', NULL, NULL,
               '{"lineage":{"parentThreadId":"t5","rootThreadId":"t5","relationshipToParent":"subagent"}}'),
              ('t7', 'p1', 'Settled but running again', 'claudeAgent', '2026-10-17T10:00:00Z', '2026-10-18T12:00:00Z', NULL, NULL, '{"settledOverride":"settled"}'),
              ('t8', 'p1', 'Snoozed', 'claudeAgent', '2026-10-17T10:00:00Z', '2026-10-18T12:00:00Z', NULL, NULL, '{"snoozedUntil":"2999-01-01T00:00:00.000Z"}'),
              ('t9', 'p1', 'Done, seen before it finished', 'claudeAgent', '2026-10-17T10:00:00Z', '2026-10-19T08:00:00Z', NULL, NULL,
               '{"lastVisitedAt":"2026-10-19T07:00:00.000Z","snoozedUntil":"2026-01-01T00:00:00.000Z"}');
            INSERT INTO projection_thread_pull_requests VALUES
              ('t1', 'github.com', 'jagadhis/oorva-app', 999, 'https://github.com/jagadhis/oorva-app/pull/999', 'agent', '2026-10-19T03:00:00Z',
               '{"state":"open","title":"Stale legacy row the reader ignores"}');
            CREATE TABLE orchestration_v2_projection_turn_items (
              turn_item_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, ordinal INTEGER NOT NULL, type TEXT NOT NULL,
              status TEXT NOT NULL, updated_at TEXT NOT NULL, payload_json TEXT NOT NULL);
            INSERT INTO orchestration_v2_projection_turn_items VALUES
              ('i1', 't5', 1, 'dynamic_tool', 'completed', '2026-10-18T12:00:00Z',
               '{"toolName":"mcp__t3-code__t3_thread_launch","status":"completed","output":{"structuredContent":{"threadId":"t9","status":"preparing"}}}'),
              ('i2', 't9', 1, 'dynamic_tool', 'completed', '2026-10-19T08:00:00Z',
               '{"toolName":"t3-code.create_threads","status":"completed","output":{"content":"{\\"threads\\":[{\\"threadId\\":\\"t7\\"},{\\"threadId\\":\\"t8\\"}]}"}}'),
              ('i3', 't9', 2, 'dynamic_tool', 'completed', '2026-10-19T08:00:00Z',
               '{"toolName":"Read","status":"completed","output":{"content":"mentions t3_thread_launch and {\\"threadId\\":\\"t1\\"}"}}'),
              ('i4', 't1', 1, 'dynamic_tool', 'running', '2026-10-19T08:00:00Z',
               '{"toolName":"mcp__t3-code__t3_thread_launch","status":"running","output":null}');
            """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return url
    }

    @Test func readsActiveThreadsWithProjectsAndPullRequests() throws {
        let url = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let threads = try T3CodeStateReader(databaseURL: url).activeThreads().filter { ["t1", "t2"].contains($0.id) }

        #expect(threads.map(\.id) == ["t1", "t2"])
        let voice = threads[0]
        #expect(voice.projectName == "oorva-app")
        #expect(voice.projectRoot == "/Users/jags/projects/oorva-app")
        #expect(voice.branch == "feat/voice-bulbul-v4-flash")
        #expect(voice.worktreePath == "/Users/jags/projects/oorva-app")
        #expect(voice.provider == "claudeAgent_4")
        #expect(voice.updatedAt == T3CodeStateReader.date("2026-10-19T03:12:00.500Z"))
        #expect(voice.updatedAt != nil)
        // Pull requests come from the thread's payload; dismissed stack members are hidden.
        #expect(voice.pullRequests.map(\.number) == [188])
        let pullRequest = try #require(voice.pullRequests.first)
        #expect(pullRequest.status == .open)
        #expect(pullRequest.title == "Voice relay on Bulbul v4 Flash")
        #expect(pullRequest.headBranch == "feat/voice-bulbul-v4-flash")
        #expect(pullRequest.baseBranch == "main")
        #expect(pullRequest.author == "jagadhis")
        #expect(pullRequest.additions == 120)
        #expect(pullRequest.checks == .failing)
        #expect(pullRequest.review == .reviewRequired)
        #expect(pullRequest.source == "agent")
        #expect(pullRequest.syncedAt == T3CodeStateReader.date("2026-10-19T03:10:00Z"))
        #expect(pullRequest.nextStep == .fixChecks)
        // A thread whose project was deleted reads as having no project.
        #expect(threads[1].projectName == nil)
        #expect(threads[1].provider == "codex")
        // Lineage, latest run and pending requests.
        #expect(voice.latestRunStatus == "running")
        #expect(voice.hasPendingRequest)
        #expect(voice.parentThreadId == nil)
        #expect(threads[1].parentThreadId == "t1")
        #expect(threads[1].rootThreadId == "t1")
        #expect(threads[1].relationshipToParent == "subagent")
        #expect(threads[1].latestRunStatus == nil)
        #expect(threads[1].hasPendingRequest == false)
    }

    @Test func skipsSettledAndSnoozedTasksUnlessLiveOrOpen() throws {
        let url = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = T3CodeStateReader(databaseURL: url)

        // Settled tasks and their sub-threads, and snoozed threads, are skipped;
        // a settled thread with a live run and a thread whose snooze ended are read.
        let ids = Set(try reader.activeThreads().map(\.id))
        #expect(ids == ["t1", "t2", "t7", "t9"])

        // A task open in cmux is read with its sub-threads even when settled.
        let open = try reader.activeThreads(openTaskIds: ["t5"])
        #expect(Set(open.map(\.id)) == ["t1", "t2", "t5", "t6", "t7", "t9"])
        #expect(open.first { $0.id == "t5" }?.isSettled == true)
        #expect(open.first { $0.id == "t6" }?.isSettled == true)
        #expect(open.first { $0.id == "t9" }?.isSettled == false)
    }

    @Test func readsIncludedThreadsEvenWhenSettled() throws {
        let url = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        // A settled thread a listed thread was handed off from is read, without its sub-threads.
        let ids = Set(try T3CodeStateReader(databaseURL: url).activeThreads(includingThreadIds: ["t5"]).map(\.id))
        #expect(ids == ["t1", "t2", "t5", "t7", "t9"])
    }

    @Test func indexesThreadLaunchesIncrementally() throws {
        let url = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = T3CodeStateReader(databaseURL: url)

        var index = T3LaunchIndex()
        try reader.updateLaunchIndex(&index)
        // t3_thread_launch's structured result and create_threads' JSON text both count;
        // a tool that only mentions the name doesn't.
        #expect(index.launcherByThreadId == ["t9": "t5", "t7": "t9", "t8": "t9"])
        #expect(index.hasScanned)
        // The unfinished launch is read again next time.
        #expect(index.unfinishedRowIds.count == 1)
        // A read that hasn't scanned yet never replaces one that has.
        #expect(index.isAhead(of: T3LaunchIndex()))
        #expect(!T3LaunchIndex().isAhead(of: index))
        let beforeFinish = index

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let finish = """
            UPDATE orchestration_v2_projection_turn_items
              SET payload_json = '{"toolName":"mcp__t3-code__t3_thread_launch","status":"completed","output":{"structuredContent":{"threadId":"t6"}}}'
              WHERE turn_item_id = 'i4';
            """
        #expect(sqlite3_exec(db, finish, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        try reader.updateLaunchIndex(&index)
        #expect(index.launcher(of: "t6") == "t1")
        #expect(index.unfinishedRowIds.isEmpty)
        #expect(index.isAhead(of: beforeFinish))
        #expect(!beforeFinish.isAhead(of: index))

        // The index survives a round trip to disk.
        let saved = try JSONDecoder().decode(T3LaunchIndex.self, from: JSONEncoder().encode(index))
        #expect(saved == index)

        // The index fills in launchers T3 didn't record on the thread.
        let threads = index.applied(to: try reader.activeThreads())
        #expect(threads.first { $0.id == "t9" }?.launchedByThreadId == "t5")
        #expect(threads.first { $0.id == "t1" }?.launchedByThreadId == nil)
    }

    @Test func compactionRereadsHistoryButKeepsKnownLaunches() throws {
        let url = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = T3CodeStateReader(databaseURL: url)
        let marker = reader.compactionMarkerURL
        defer { try? FileManager.default.removeItem(at: marker) }
        try "100".write(to: marker, atomically: true, encoding: .utf8)

        var index = T3LaunchIndex()
        try reader.updateLaunchIndex(&index)
        let scanned = index
        #expect(scanned.compactionMarker == "100")

        // Nothing changed: an incremental read keeps the cursor.
        try reader.updateLaunchIndex(&index, allowsFullRead: false)
        #expect(index.hasScanned)

        // T3 compacted: the cursor starts over, but known launches stay so tasks stay grouped.
        try "200".write(to: marker, atomically: true, encoding: .utf8)
        try reader.updateLaunchIndex(&index, allowsFullRead: false)
        #expect(!index.hasScanned)
        #expect(index.launcher(of: "t9") == "t5")
        // The reset index replaces the older one, though it has read less so far.
        #expect(index.isAhead(of: scanned))
        try reader.updateLaunchIndex(&index)
        #expect(index.hasScanned)
        #expect(index.compactionMarker == "200")
        #expect(index.launcherByThreadId == scanned.launcherByThreadId)
    }

    @Test func onlyInFlightLaunchesAreReadAgain() {
        var index = T3LaunchIndex()
        index.record(rowId: 1, threadId: "a", toolName: "mcp__t3-code__t3_thread_launch", status: "cancelled", output: nil)
        index.record(rowId: 2, threadId: "a", toolName: "mcp__t3-code__t3_thread_launch", status: "interrupted", output: nil)
        index.record(rowId: 3, threadId: "a", toolName: "mcp__t3-code__t3_thread_launch", status: "running", output: nil)
        index.record(rowId: 4, threadId: "a", toolName: "Read", status: "running", output: nil)
        #expect(index.unfinishedRowIds == [3])
    }

    @Test func readsCompletionAndVisitTimes() throws {
        let url = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let done = try #require(try T3CodeStateReader(databaseURL: url).activeThreads().first { $0.id == "t9" })
        #expect(done.latestRunStatus == "completed")
        #expect(done.latestRunCompletedAt == T3CodeStateReader.date("2026-10-19T08:00:00.250Z"))
        #expect(done.lastVisitedAt == T3CodeStateReader.date("2026-10-19T07:00:00.000Z"))
        #expect(done.hasUnseenResult)
        #expect(T3ThreadStatus.of(done) == .done)
    }

    @Test func readsProjectsAndPullRequestThreads() throws {
        let url = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = T3CodeStateReader(databaseURL: url)

        #expect(try reader.projects().map(\.name) == ["oorva-app"])
        let links = try reader.pullRequestThreads()
        #expect(links["jagadhis/oorva-app#188"] == T3CodeStateReader.PullRequestThread(
            threadId: "t1", title: "Voice Relay Production Deployment", taskId: "t1"
        ))
    }

    @Test func missingDatabaseThrows() {
        let reader = T3CodeStateReader(databaseURL: URL(fileURLWithPath: "/nonexistent/statev2.sqlite"))
        #expect(throws: T3CodeStateReader.ReadError.self) { try reader.activeThreads() }
    }

    @Test func parsesDatesWithAndWithoutFractionalSeconds() {
        #expect(T3CodeStateReader.date("2026-10-19T03:12:00.500Z") != nil)
        #expect(T3CodeStateReader.date("2026-10-19T03:12:00Z") != nil)
        #expect(T3CodeStateReader.date("yesterday") == nil)
    }
}
