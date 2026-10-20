import Foundation
import Testing
@testable import CmuxAgentHome

@Suite struct T3ThreadGroupingTests {
    func thread(
        _ id: String,
        project: String? = "oorva-app",
        title: String = "Thread",
        branch: String? = "feat/voice-bulbul-v4-flash",
        worktree: String? = "/Users/jags/projects/oorva-app",
        updated: TimeInterval = 0,
        pullRequests: [T3Thread.PullRequest] = []
    ) -> T3Thread {
        T3Thread(
            id: id, projectId: project ?? "none", projectName: project, title: title,
            branch: branch, worktreePath: worktree, provider: "claudeAgent_2",
            updatedAt: Date(timeIntervalSince1970: updated), pullRequests: pullRequests
        )
    }

    @Test func threadsOnTheSameBranchBecomeOneTask() {
        let result = T3ThreadGrouping.group([
            thread("a", title: "Voice Relay Production Deployment", updated: 30,
                   pullRequests: [T3Thread.PullRequest(repository: "jagadhis/oorva-app", number: 188, state: "open")]),
            thread("b", title: "Traveller Feedback and Booking Conversion", updated: 20),
            thread("c", project: "devjags-portfolio", title: "Highlight MCP in Portfolio", branch: "feat/mcp-server", updated: 10),
        ])

        #expect(result.tasks.count == 2)
        let voice = result.tasks[0]
        #expect(voice.title == "Voice bulbul v4 flash")
        #expect(voice.threads.map(\.id) == ["a", "b"])
        #expect(voice.pullRequest?.number == 188)
        #expect(voice.worktreePath == "/Users/jags/projects/oorva-app")
        // A lone thread keeps its own title.
        #expect(result.tasks[1].title == "Highlight MCP in Portfolio")
        #expect(result.unsorted.isEmpty)
    }

    @Test func sameBranchInDifferentProjectsStaysSeparate() {
        let result = T3ThreadGrouping.group([
            thread("a", project: "one", branch: "feat/x"),
            thread("b", project: "two", branch: "feat/x"),
        ])
        #expect(result.tasks.count == 2)
    }

    @Test func defaultBranchScratchAndProjectlessThreadsAreUnsorted() {
        let result = T3ThreadGrouping.group(
            [
                thread("main", branch: "main", updated: 3),
                thread("nobranch", branch: nil, updated: 2),
                thread("scratch", project: "workspace", branch: "feat/x", worktree: "/Users/jags/.t3/scratch/2026-10-19-x", updated: 1),
                thread("loose", project: nil, updated: 4),
            ],
            scratchDirectory: "/Users/jags/.t3/scratch"
        )

        #expect(result.tasks.isEmpty)
        #expect(result.unsorted.map(\.id) == ["loose", "main", "nobranch", "scratch"])
        #expect(result.unsorted.map(\.reason) == [.noProject, .defaultBranch, .defaultBranch, .noProject])
    }

    @Test func tasksAreOrderedByMostRecentThread() {
        let result = T3ThreadGrouping.group([
            thread("old", branch: "feat/old", updated: 5),
            thread("new", branch: "feat/new", updated: 50),
            thread("mid", branch: "feat/old", updated: 20),
        ])
        #expect(result.tasks.map(\.branch) == ["feat/new", "feat/old"])
        #expect(result.tasks[1].threads.map(\.id) == ["mid", "old"])
    }

    @Test func humanizesBranches() {
        #expect(T3ThreadGrouping.humanize(branch: "redesign/ai-systems-engineer") == "AI systems engineer")
        #expect(T3ThreadGrouping.humanize(branch: "feat/mcp-server") == "MCP server")
        #expect(T3ThreadGrouping.humanize(branch: "fix_seo_titles") == "Fix SEO titles")
    }

    @Test func agentKindFromProvider() {
        #expect(thread("a").agentKind == .claude)
        var codex = thread("b")
        codex.provider = "codex_1"
        #expect(codex.agentKind == .codex)
    }
}
