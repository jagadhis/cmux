import Foundation
import Testing
@testable import CmuxAgentHome

@Suite struct AgentSessionFilesTests {
    @Test func classifiesWorkingMemoryAndPlans() {
        #expect(AgentSessionFile.kind(ofPath: "/Users/me/workspace/work-memory/items/BD-191/current.md") == .workingMemory)
        #expect(AgentSessionFile.kind(ofPath: "/Users/me/projects/app/working-memory/2026-10-02-pricing.md") == .workingMemory)
        #expect(AgentSessionFile.kind(ofPath: "/Users/me/.claude/projects/-Users-me-app/memory/supabase.md") == .workingMemory)
        #expect(AgentSessionFile.kind(ofPath: "/Users/me/projects/app/MEMORY.md") == .workingMemory)
        #expect(AgentSessionFile.kind(ofPath: "/Users/me/workspace/work-plans/2026-10-20-BD-191.md") == .plan)
        #expect(AgentSessionFile.kind(ofPath: "/Users/me/.claude/plans/quiet-otter.md") == .plan)
        #expect(AgentSessionFile.kind(ofPath: "/Users/me/projects/app/src/memory/cache.ts") == .file)
        #expect(AgentSessionFile.kind(ofPath: "/Users/me/projects/app/work-memory.md") == .file)
    }

    @Test func showsPathsRelativeToTheProjectOrHome() {
        let file = AgentSessionFile(path: "/Users/me/projects/app/src/relay.ts")
        #expect(file.displayPath(relativeTo: "/Users/me/projects/app", home: "/Users/me") == "src/relay.ts")
        #expect(file.displayPath(relativeTo: "/Users/me/projects/app/", home: "/Users/me") == "src/relay.ts")
        #expect(file.displayPath(relativeTo: "/Users/me/projects/ap", home: "/Users/me") == "~/projects/app/src/relay.ts")
        #expect(AgentSessionFile(path: "/tmp/x.md").displayPath(relativeTo: nil, home: "/Users/me") == "/tmp/x.md")
    }

    @Test func recordsClaudeEditsWithCountsAndTimes() {
        var log = AgentSessionFileLog()
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)
        log.record(toolName: "Edit", toolInputJSON: #"{"file_path":"/w/work-memory/a/current.md","old_string":"x"}"#, workingDirectory: "/repo", at: early)
        log.record(toolName: "Write", toolInputJSON: #"{"file_path":"src/new.ts","content":""}"#, workingDirectory: "/repo", at: early)
        log.record(toolName: "Edit", toolInputJSON: #"{"file_path":"/w/work-memory/a/current.md"}"#, workingDirectory: "/repo", at: late)
        log.record(toolName: "NotebookEdit", toolInputJSON: #"{"notebook_path":"/repo/n.ipynb"}"#, workingDirectory: "/repo", at: early)
        log.record(toolName: "Read", toolInputJSON: #"{"file_path":"/repo/read-only.ts"}"#, workingDirectory: "/repo", at: late)
        log.record(toolName: "Bash", toolInputJSON: #"{"command":"ls"}"#, workingDirectory: "/repo", at: late)

        let files = log.files
        #expect(files.map(\.path) == ["/w/work-memory/a/current.md", "/repo/n.ipynb", "/repo/src/new.ts"])
        #expect(files[0].editCount == 2)
        #expect(files[0].lastEditedAt == late)
    }

    @Test func readsCodexPatches() {
        let patch = """
            *** Begin Patch
            *** Update File: src/old.ts
            *** Move to: src/new.ts
            @@
            -a
            +b
            *** Add File: ../workspace/work-memory/x/current.md
            +hello
            *** Delete File: src/gone.ts
            *** End Patch
            """
        let json = String(data: try! JSONSerialization.data(withJSONObject: ["command": ["apply_patch", patch]]), encoding: .utf8)
        let paths = AgentSessionFileLog.writtenPaths(toolName: "shell", toolInputJSON: json, workingDirectory: "/Users/me/repo")
        #expect(paths == ["/Users/me/repo/src/new.ts", "/Users/me/workspace/work-memory/x/current.md"])
        // A raw, non-JSON patch input works too.
        #expect(AgentSessionFileLog.writtenPaths(toolName: "apply_patch", toolInputJSON: patch, workingDirectory: "/r").count == 2)
    }

    @Test func mergesSessionsIntoATaskList() {
        let a = [AgentSessionFile(path: "/m.md", editCount: 2, lastEditedAt: Date(timeIntervalSince1970: 10))]
        let b = [
            AgentSessionFile(path: "/m.md", editCount: 1, lastEditedAt: Date(timeIntervalSince1970: 30)),
            AgentSessionFile(path: "/c.ts", editCount: 1, lastEditedAt: Date(timeIntervalSince1970: 20)),
        ]
        let merged = AgentSessionFile.merged([a, b])
        #expect(merged.map(\.path) == ["/m.md", "/c.ts"])
        #expect(merged[0].editCount == 3)
        #expect(merged[0].lastEditedAt == Date(timeIntervalSince1970: 30))
    }
}
