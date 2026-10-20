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
               '{"branch":"feat/voice-bulbul-v4-flash","worktreePath":"/Users/jags/projects/oorva-app","providerInstanceId":"claudeAgent_4"}'),
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
              ('t1', 'github.com', 'jagadhis/oorva-app', 188, 'https://github.com/jagadhis/oorva-app/pull/188', 'agent', '2026-10-19T03:00:00Z',
               '{"state":"open","title":"Voice relay on Bulbul v4 Flash"}');
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
        #expect(voice.pullRequests.first?.number == 188)
        #expect(voice.pullRequests.first?.state == "open")
        #expect(voice.pullRequests.first?.title == "Voice relay on Bulbul v4 Flash")
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
