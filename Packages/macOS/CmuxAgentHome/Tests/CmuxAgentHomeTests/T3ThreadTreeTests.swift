import Foundation
import Testing
@testable import CmuxAgentHome

@Suite struct T3ThreadTreeTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func thread(
        _ id: String, project: String? = "oorva-app", parent: String? = nil, root: String? = nil,
        run: String? = "completed", pending: Bool = false, daysAgo: Double = 0, settled: Bool = false,
        launchedBy: String? = nil, createdDaysAgo: Double? = nil
    ) -> T3Thread {
        T3Thread(
            id: id, projectId: project ?? "none", projectName: project, title: id, provider: "claudeAgent",
            createdAt: now.addingTimeInterval(-(createdDaysAgo ?? daysAgo) * 86_400),
            updatedAt: now.addingTimeInterval(-daysAgo * 86_400),
            parentThreadId: parent, rootThreadId: root ?? parent, relationshipToParent: parent == nil ? nil : "subagent",
            launchedByThreadId: launchedBy,
            latestRunStatus: run, hasPendingRequest: pending, isSettled: settled
        )
    }

    @Test func statusNeedsAnActiveRun() {
        #expect(T3ThreadStatus.of(thread("a", run: "running")) == .running)
        #expect(T3ThreadStatus.of(thread("a", run: "running", pending: true)) == .needsYou)
        #expect(T3ThreadStatus.of(thread("a", run: "waiting")) == .needsYou)
        // A stale pending request on a finished thread doesn't count.
        #expect(T3ThreadStatus.of(thread("a", run: "completed", pending: true)) == .done)
        #expect(T3ThreadStatus.of(thread("a", run: nil)) == .idle)
    }

    @Test func finishedThreadsAreDoneUntilSettled() {
        #expect(T3ThreadStatus.of(thread("a", run: "completed")) == .done)
        #expect(T3ThreadStatus.of(thread("a", run: "failed")) == .done)
        #expect(T3ThreadStatus.of(thread("a", run: "completed", settled: true)) == .idle)
        // A settled thread that runs again is live again.
        #expect(T3ThreadStatus.of(thread("a", run: "running", settled: true)) == .running)
        #expect(thread("a", run: "interrupted").latestRunEndedEarly)
        #expect(!thread("a", run: "completed").latestRunEndedEarly)
    }

    @Test func unseenResultsCompareCompletionWithTheLastVisit() {
        var seen = thread("a")
        seen.latestRunCompletedAt = now
        seen.lastVisitedAt = now.addingTimeInterval(60)
        #expect(!seen.hasUnseenResult)
        var unseen = seen
        unseen.lastVisitedAt = now.addingTimeInterval(-60)
        #expect(unseen.hasUnseenResult)
        #expect(T3TaskNode(thread: unseen).hasUnseenResult)
        // Never visited: T3 doesn't count it as unseen either.
        unseen.lastVisitedAt = nil
        #expect(!unseen.hasUnseenResult)
        // Settled results aren't waiting on anyone.
        var settled = seen
        settled.lastVisitedAt = now.addingTimeInterval(-60)
        settled.isSettled = true
        #expect(!T3TaskNode(thread: settled).hasUnseenResult)
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

    @Test func subAgentsRunInsideTheirParentsRun() {
        var native = thread("review", parent: "main", run: nil)
        native.subagent = T3Thread.Subagent(origin: "provider_native", status: "running", progress: "Reading the diff")
        #expect(T3ThreadStatus.of(native) == .running)
        native.subagent?.status = "completed"
        #expect(T3ThreadStatus.of(native) == .idle)
        #expect(!native.latestRunEndedEarly)
        native.subagent?.status = "interrupted"
        #expect(native.latestRunEndedEarly)
        // A delegated task has runs of its own, and they win.
        var delegated = thread("delegated", parent: "main", run: "completed")
        delegated.subagent = T3Thread.Subagent(origin: "app_owned", status: "running")
        #expect(T3ThreadStatus.of(delegated) == .done)
    }

    @Test func subThreadsListUnderTheThreadThatStartedThem() {
        let task = T3ThreadTree.build([
            thread("main", run: "running", daysAgo: 0),
            thread("old-helper", parent: "main", run: nil, daysAgo: 3),
            thread("live-helper", parent: "main", run: "running", daysAgo: 1),
            thread("nested", parent: "live-helper", root: "main", run: nil, daysAgo: 0.5),
            thread("handoff", run: "completed", daysAgo: 0.2, launchedBy: "main", createdDaysAgo: 0.4),
            thread("handoff-helper", parent: "handoff", run: nil, daysAgo: 0.1),
            // Its parent is gone, so it lists under the lineage root.
            thread("stray", parent: "gone", root: "main", run: nil, daysAgo: 2),
        ], now: now)[0].recentTasks[0]

        let outline = task.subThreadOutline()
        func rows(_ id: String) -> [String] { outline.rows(under: id).map { "\($0.depth):\($0.id)" } }
        // Live first, then newest; each sub-thread is followed by its own.
        #expect(rows("main") == ["1:live-helper", "2:nested", "1:stray", "1:old-helper"])
        #expect(rows("handoff") == ["1:handoff-helper"])
        #expect(outline.rows(under: "nested").isEmpty)
        #expect(outline.rows(under: "main").first { $0.id == "nested" }?.parent?.id == "live-helper")
        #expect(outline.hiddenCount == 0)
    }

    @Test func collapsedOutlinesKeepLiveSubThreadsAndTheirParents() {
        let task = T3ThreadTree.build([
            thread("main", run: "completed", daysAgo: 0),
            thread("done-parent", parent: "main", run: nil, daysAgo: 2),
            thread("live-child", parent: "done-parent", root: "main", run: "running", daysAgo: 1),
            thread("done-a", parent: "main", run: nil, daysAgo: 0.5),
            thread("done-b", parent: "main", run: nil, daysAgo: 0.6),
        ], now: now)[0].recentTasks[0]

        // Only live sub-threads, with the parents that link them to the main thread.
        let live = task.subThreadOutline(finishedLimit: 0)
        #expect(live.rows(under: "main").map(\.id) == ["done-parent", "live-child"])
        #expect(live.hiddenCount == 2)
        // Finished ones fill up to the limit after those.
        let some = task.subThreadOutline(finishedLimit: 1)
        #expect(some.rows(under: "main").map(\.id) == ["done-parent", "live-child", "done-a"])
        #expect(some.hiddenCount == 1)
    }

    @Test func handoffsGroupUnderTheThreadThatStartedTheChain() {
        let projects = T3ThreadTree.build([
            thread("main", daysAgo: 2, settled: true),
            thread("main-helper", parent: "main", daysAgo: 2),
            thread("second", run: "completed", daysAgo: 1, launchedBy: "main", createdDaysAgo: 1.5),
            thread("third", run: "running", daysAgo: 0, launchedBy: "second", createdDaysAgo: 1),
            // A thread a sub-thread launched still belongs to the chain.
            thread("from-helper", daysAgo: 0.2, launchedBy: "main-helper", createdDaysAgo: 1.2),
            thread("third-helper", parent: "third", run: "running"),
            thread("launcher-gone", daysAgo: 3, launchedBy: "archived"),
        ], now: now)

        let tasks = projects[0].recentTasks
        #expect(tasks.map(\.id) == ["main", "launcher-gone"])
        let main = tasks[0]
        // Handoffs read top down, oldest first; sub-threads of any of them nest too.
        #expect(main.handoffs.map(\.id) == ["second", "from-helper", "third"])
        #expect(Set(main.subThreads.map(\.id)) == ["main-helper", "third-helper"])
        #expect(main.mainThreads.map(\.id) == ["main", "second", "from-helper", "third"])
        // The task takes its most urgent thread's status, though the main thread is settled.
        #expect(main.status == .running)
        #expect(main.thread(withId: "third")?.id == "third")
    }

    @Test func handoffCyclesDoNotLoop() {
        let projects = T3ThreadTree.build([
            thread("a", launchedBy: "b"),
            thread("b", launchedBy: "a"),
        ], now: now)
        let tasks = projects[0].recentTasks
        #expect(tasks.count == 1)
        #expect(tasks[0].handoffs.count == 1)
    }

    @Test func missingLaunchersAreReadUpTheChain() {
        let index = T3LaunchIndex(launchers: ["third": "second", "second": "main"])
        let threads = index.applied(to: [thread("third", run: "running")])
        #expect(threads[0].launchedByThreadId == "second")
        #expect(T3ThreadTree.missingLaunchers(of: threads, index: index) == ["second", "main"])
        #expect(T3ThreadTree.missingLaunchers(of: [thread("solo")], index: index).isEmpty)
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
            thread("fresh", daysAgo: 1, settled: true),
            thread("old", daysAgo: 30, settled: true),
            thread("old-but-running", run: "running", daysAgo: 30),
            thread("waiting", run: "running", pending: true, daysAgo: 3),
            thread("old-unverified", daysAgo: 30),
        ], now: now)
        // Unverified results stay in view however old they are.
        #expect(projects[0].recentTasks.map(\.id) == ["waiting", "old-but-running", "old-unverified", "fresh"])
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
