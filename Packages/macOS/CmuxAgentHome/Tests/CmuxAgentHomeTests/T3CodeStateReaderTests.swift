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
            CREATE TABLE projection_thread_pull_requests (
              thread_id TEXT NOT NULL, host TEXT NOT NULL, repository TEXT NOT NULL, number INTEGER NOT NULL,
              url TEXT NOT NULL, source TEXT NOT NULL, linked_at TEXT NOT NULL, snapshot_json TEXT);
            INSERT INTO projection_projects VALUES ('p1', 'oorva-app', '/Users/jags/projects/oorva-app', NULL), ('p2', 'gone', '/tmp/gone', '2026-10-01T00:00:00Z');
            INSERT INTO orchestration_v2_projection_threads VALUES
              ('t1', 'p1', 'Voice Relay Production Deployment', 'claudeAgent', '2026-10-18T10:00:00.000Z', '2026-10-19T03:12:00.500Z', NULL, NULL,
               '{"branch":"feat/voice-bulbul-v4-flash","worktreePath":"/Users/jags/projects/oorva-app","providerInstanceId":"claudeAgent_4"}'),
              ('t2', 'p2', 'In a deleted project', 'codex', '2026-10-17T10:00:00Z', '2026-10-17T11:00:00Z', NULL, NULL, '{}'),
              ('t3', 'p1', 'Archived', 'claudeAgent', '2026-10-17T10:00:00Z', '2026-10-19T09:00:00Z', '2026-10-19T09:00:00Z', NULL, '{}'),
              ('t4', 'p1', 'Deleted', 'claudeAgent', '2026-10-17T10:00:00Z', '2026-10-19T09:00:00Z', NULL, '2026-10-19T09:00:00Z', '{}');
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

        let threads = try T3CodeStateReader(databaseURL: url).activeThreads()

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
