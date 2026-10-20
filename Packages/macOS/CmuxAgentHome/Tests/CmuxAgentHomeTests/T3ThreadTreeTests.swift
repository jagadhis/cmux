import Foundation
import Testing
@testable import CmuxAgentHome

@Suite struct T3ThreadTreeTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func thread(
        _ id: String, project: String? = "oorva-app", parent: String? = nil, root: String? = nil,
        run: String? = "completed", pending: Bool = false, daysAgo: Double = 0
    ) -> T3Thread {
        T3Thread(
            id: id, projectId: project ?? "none", projectName: project, title: id, provider: "claudeAgent",
            updatedAt: now.addingTimeInterval(-daysAgo * 86_400),
            parentThreadId: parent, rootThreadId: root ?? parent, relationshipToParent: parent == nil ? nil : "subagent",
            latestRunStatus: run, hasPendingRequest: pending
        )
    }

    @Test func statusNeedsAnActiveRun() {
        #expect(T3ThreadStatus.of(thread("a", run: "running")) == .running)
        #expect(T3ThreadStatus.of(thread("a", run: "running", pending: true)) == .needsYou)
        #expect(T3ThreadStatus.of(thread("a", run: "waiting")) == .needsYou)
        // A stale pending request on a finished thread doesn't count.
        #expect(T3ThreadStatus.of(thread("a", run: "completed", pending: true)) == .idle)
        #expect(T3ThreadStatus.of(thread("a", run: nil)) == .idle)
    }

    @Test func subThreadsNestUnderTheirRoot() {
        let projects = T3ThreadTree.build([
            thread("root", daysAgo: 1),
            thread("child", parent: "root", run: "running"),
            thread("grandchild", parent: "child", root: "root", daysAgo: 0.5),
            thread("other", daysAgo: 2),
        ], now: now)

        #expect(projects.count == 1)
        let tasks = projects[0].recentTasks
        #expect(tasks.map(\.id) == ["root", "other"])
        #expect(tasks[0].subThreads.map(\.id) == ["child", "grandchild"])
        #expect(tasks[0].status == .running)
        #expect(tasks[0].liveSubThreadCount == 1)
    }

    @Test func missingRootFallsBackToNearestAncestorOrItself() {
        let projects = T3ThreadTree.build([
            thread("mid", parent: "gone", root: "gone"),
            thread("leaf", parent: "mid", root: "gone"),
            thread("orphan", parent: "also-gone", root: "also-gone"),
        ], now: now)
        let tasks = projects[0].recentTasks
        #expect(Set(tasks.map(\.id)) == ["mid", "orphan"])
        #expect(tasks.first { $0.id == "mid" }?.subThreads.map(\.id) == ["leaf"])
    }

    @Test func quietOldTasksAreOlderAndLiveOnesStayRecent() {
        let projects = T3ThreadTree.build([
            thread("fresh", daysAgo: 1),
            thread("old", daysAgo: 30),
            thread("old-but-running", run: "running", daysAgo: 30),
            thread("waiting", run: "running", pending: true, daysAgo: 3),
        ], now: now)
        #expect(projects[0].recentTasks.map(\.id) == ["waiting", "old-but-running", "fresh"])
        #expect(projects[0].olderTasks.map(\.id) == ["old"])
    }

    @Test func projectsSortByActivityAndProjectlessThreadsShareOneBucket() {
        let projects = T3ThreadTree.build([
            thread("a", project: "quiet", daysAgo: 5),
            thread("b", project: "busy", daysAgo: 0),
            thread("c", project: nil, daysAgo: 1),
            thread("d", project: nil, daysAgo: 2),
        ], now: now)
        #expect(projects.map(\.name) == ["busy", "", "quiet"])
        #expect(projects[1].id == "")
        #expect(projects[1].recentTasks.count == 2)
    }
}
