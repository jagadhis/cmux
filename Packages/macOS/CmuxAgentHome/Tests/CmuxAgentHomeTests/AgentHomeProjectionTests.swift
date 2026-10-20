import Foundation
import Testing
@testable import CmuxAgentHome

@Suite struct AgentHomeProjectionTests {
    let app = AgentHomeProjectInput(id: UUID(), name: "oorva-app", colorHex: "#D9734A")
    let autopilot = AgentHomeProjectInput(id: UUID(), name: "autopilot")

    func agent(_ state: AgentHomeAgentState, permission: AgentHomePermissionRequest? = nil, cost: Double? = nil) -> AgentHomeAgent {
        AgentHomeAgent(id: UUID().uuidString, kind: .claude, title: "Agent", state: state, estimatedCostUSD: cost, pendingPermission: permission)
    }

    @Test func pendingPermissionForcesNeedsYou() {
        let permission = AgentHomePermissionRequest(requestId: "r1", toolName: "Bash", summary: "fly deploy", canAlwaysAllow: true)
        let card = agent(.running, permission: permission)
        #expect(card.state == .needsYou)
    }

    @Test func liveAgentStateWinsOverLane() {
        let waiting = AgentHomeTaskInput(id: UUID(), title: "Deploy", lane: .working, agents: [agent(.running), agent(.needsYou)])
        let running = AgentHomeTaskInput(id: UUID(), title: "Review", lane: .todo, agents: [agent(.idle), agent(.running)])
        #expect(AgentHomeProjection.status(of: waiting) == .needsYou)
        #expect(AgentHomeProjection.status(of: running) == .running)
    }

    @Test func dirtyTreeAloneIsNotRunning() {
        // `working` is also inferred from a dirty git tree; without a working agent it isn't live work.
        let dirty = AgentHomeTaskInput(id: UUID(), title: "Dirty", lane: .working, agents: [agent(.idle)])
        let dirtyWithPR = AgentHomeTaskInput(
            id: UUID(), title: "Dirty PR", lane: .working,
            pullRequest: AgentHomePullRequest(number: 1, title: "PR", state: .open)
        )
        #expect(AgentHomeProjection.status(of: dirty) == .idle)
        #expect(AgentHomeProjection.status(of: dirtyWithPR) == .readyForReview)
    }

    @Test func quietTaskStatusFollowsPullRequest() {
        let open = AgentHomeTaskInput(id: UUID(), title: "Open", pullRequest: AgentHomePullRequest(number: 1, title: "A", state: .open))
        let merged = AgentHomeTaskInput(id: UUID(), title: "Merged", pullRequest: AgentHomePullRequest(number: 2, title: "B", state: .merged))
        let none = AgentHomeTaskInput(id: UUID(), title: "None")
        #expect(AgentHomeProjection.status(of: open) == .readyForReview)
        #expect(AgentHomeProjection.status(of: merged) == .done)
        #expect(AgentHomeProjection.status(of: none) == .idle)
    }

    @Test func snapshotGroupsTasksAndKeepsWorkspaceOrder() {
        let first = AgentHomeTaskInput(id: UUID(), title: "Voice relay", projectId: app.id, agents: [agent(.needsYou)])
        let loose = AgentHomeTaskInput(id: UUID(), title: "Loose")
        let second = AgentHomeTaskInput(id: UUID(), title: "Booking", projectId: app.id, agents: [agent(.running)])
        let cockpit = AgentHomeTaskInput(id: UUID(), title: "Cockpit", projectId: autopilot.id, lane: .review)
        let orphan = AgentHomeTaskInput(id: UUID(), title: "Orphan", projectId: UUID())

        let snapshot = AgentHomeProjection.snapshot(projects: [app, autopilot], tasks: [first, loose, second, cockpit, orphan])

        #expect(snapshot.projects.map(\.input.name) == ["oorva-app", "autopilot"])
        #expect(snapshot.projects[0].tasks.map(\.input.title) == ["Voice relay", "Booking"])
        #expect(snapshot.projects[0].rollupStatus == .needsYou)
        #expect(snapshot.ungroupedTasks.map(\.input.title) == ["Loose", "Orphan"])
        #expect(snapshot.count(of: .needsYou) == 1)
        #expect(snapshot.count(of: .running) == 1)
        #expect(snapshot.count(of: .readyForReview) == 1)
        #expect(snapshot.taskId(forShortcut: 1) == first.id)
        #expect(snapshot.taskId(forShortcut: 3) == cockpit.id)
        #expect(snapshot.taskId(forShortcut: 10) == nil)
        #expect(snapshot.liveAgentCount == 2)
    }

    @Test func projectHomeIsNotListedButStillCounts() {
        let home = AgentHomeTaskInput(id: UUID(), title: "oorva-app", projectId: app.id, agents: [agent(.needsYou)])
        let task = AgentHomeTaskInput(id: UUID(), title: "Voice relay", projectId: app.id)
        var project = app
        project.homeTaskId = home.id

        let snapshot = AgentHomeProjection.snapshot(projects: [project], tasks: [home, task])

        #expect(snapshot.projects[0].home?.id == home.id)
        #expect(snapshot.projects[0].tasks.map(\.id) == [task.id])
        #expect(snapshot.projects[0].rollupStatus == .needsYou)
        #expect(snapshot.count(of: .needsYou) == 1)
        #expect(snapshot.listedTasks.map(\.id) == [task.id])
        #expect(snapshot.taskId(forShortcut: 1) == task.id)
    }

    @Test func taskTotals() {
        let start = Date(timeIntervalSince1970: 1_000)
        var early = agent(.idle, cost: 1.25)
        early.startedAt = start
        var late = agent(.running, cost: 2.5)
        late.startedAt = start.addingTimeInterval(600)
        let task = AgentHomeProjection.snapshot(projects: [], tasks: [
            AgentHomeTaskInput(
                id: UUID(), title: "T", agents: [early, late, agent(.idle)],
                changedFiles: [
                    AgentHomeChangedFile(path: "services/voice/relay.ts", additions: 42, deletions: 9),
                    AgentHomeChangedFile(path: "README.md", additions: 3, deletions: 0),
                ]
            ),
        ]).ungroupedTasks[0]

        #expect(task.estimatedCostUSD == 3.75)
        #expect(task.startedAt == start)
        #expect(task.liveAgentCount == 1)
        #expect(task.additions == 45)
        #expect(task.deletions == 9)
        #expect(task.input.changedFiles[0].directory == "services/voice/")
        #expect(task.input.changedFiles[0].fileName == "relay.ts")
        #expect(task.input.changedFiles[1].directory == "")
    }

    @Test func currentPlanStepIsFirstUnfinished() {
        var card = agent(.running)
        card.plan = [
            AgentHomePlanStep(title: "Switch model", status: .completed),
            AgentHomePlanStep(title: "Canary deploy", status: .inProgress),
            AgentHomePlanStep(title: "Docs", status: .pending),
        ]
        #expect(card.currentPlanStep?.title == "Canary deploy")
    }

    @Test func contextFractionIsClamped() {
        let card = AgentHomeAgent(id: "a", kind: .codex, title: "A", state: .idle, contextFraction: 1.4)
        #expect(card.contextFraction == 1)
    }

    @Test func agentKindFromHookKey() {
        #expect(AgentHomeAgentKind(hookAgentKey: "Claude") == .claude)
        #expect(AgentHomeAgentKind(hookAgentKey: "claude_code") == .claude)
        #expect(AgentHomeAgentKind(hookAgentKey: "codex") == .codex)
        #expect(AgentHomeAgentKind(hookAgentKey: "gemini") == .other("gemini"))
    }
}
