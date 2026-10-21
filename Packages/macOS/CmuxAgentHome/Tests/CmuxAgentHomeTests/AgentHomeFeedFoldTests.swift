import Foundation
import Testing
@testable import CmuxAgentHome

@Suite struct AgentHomeFeedFoldTests {
    let fold = AgentHomeFeedFold()

    func event(
        _ seconds: TimeInterval,
        _ payload: AgentHomeFeedEvent.Payload,
        terminal: String = "A",
        updated: TimeInterval? = nil,
        cwd: String? = "/repo"
    ) -> AgentHomeFeedEvent {
        AgentHomeFeedEvent(
            terminalKey: terminal,
            createdAt: Date(timeIntervalSince1970: seconds),
            updatedAt: Date(timeIntervalSince1970: updated ?? seconds),
            workingDirectory: cwd,
            payload: payload
        )
    }

    func permission(_ id: String, pending: Bool, command: String = "fly deploy") -> AgentHomeFeedEvent.Payload {
        .permissionRequest(
            requestId: id,
            toolName: "Bash",
            toolInputJSON: #"{"command":"\#(command)"}"#,
            isPending: pending,
            canAlwaysAllow: true
        )
    }

    @Test func pendingPermissionShowsUntilItsAnswerArrives() {
        let asked = fold.signals(for: [event(1, permission("r1", pending: true))])["A"]
        #expect(asked?.pendingPermission?.requestId == "r1")
        #expect(asked?.pendingPermission?.summary == "fly deploy")
        #expect(asked?.pendingPermission?.canAlwaysAllow == true)

        let answered = fold.signals(for: [
            event(1, permission("r1", pending: true)),
            event(2, permission("r1", pending: false)),
        ])["A"]
        #expect(answered?.pendingPermission == nil)

        // An answer to another request leaves the waiting one alone.
        let other = fold.signals(for: [
            event(1, permission("r1", pending: true)),
            event(2, permission("r0", pending: false)),
        ])["A"]
        #expect(other?.pendingPermission?.requestId == "r1")

        // A request answered in place is never pending.
        #expect(fold.signals(for: [event(1, permission("r1", pending: false))])["A"]?.pendingPermission == nil)
    }

    @Test func sessionStartBeginsAFreshCard() {
        let signals = fold.signals(for: [
            event(1, .userPrompt("Fix the login redirect")),
            event(2, .toolUse(toolName: "Edit", toolInputJSON: #"{"file_path":"/repo/a.ts"}"#)),
            event(3, .plan([AgentHomePlanStep(title: "Fix", status: .inProgress)])),
            event(4, .assistantMessage("Fixed the redirect.")),
            event(5, permission("r1", pending: true)),
            event(10, .sessionStart, updated: 11),
            event(12, .toolUse(toolName: "Read", toolInputJSON: #"{"file_path":"/repo/b.ts"}"#)),
        ])["A"]
        #expect(signals?.sessionTitle == nil)
        #expect(signals?.plan == [])
        #expect(signals?.lastSummary == nil)
        #expect(signals?.pendingPermission == nil)
        #expect(signals?.editedFiles.isEmpty == true)
        #expect(signals?.startedAt == Date(timeIntervalSince1970: 10))
        #expect(signals?.lastActivityAt == Date(timeIntervalSince1970: 12))
        #expect(signals?.currentActivity == "Reading b.ts")
    }

    @Test func appliesEventsOldestFirstWhateverTheirOrder() {
        let ordered = [
            event(1, .userPrompt("First prompt")),
            event(2, .toolUse(toolName: "Read", toolInputJSON: #"{"file_path":"/repo/src/a.ts"}"#)),
            event(3, .userPrompt("Second prompt")),
            event(4, .toolUse(toolName: "Grep", toolInputJSON: #"{"pattern":"needle"}"#)),
            event(5, .toolUse(toolName: "Write", toolInputJSON: #"{"file_path":"notes.md"}"#)),
        ]
        let expected = fold.signals(for: ordered)
        #expect(fold.signals(for: ordered.reversed()) == expected)
        #expect(fold.signals(for: [ordered[3], ordered[0], ordered[4], ordered[2], ordered[1]]) == expected)

        let signals = expected["A"]
        #expect(signals?.sessionTitle == "First prompt")
        #expect(signals?.currentActivity == "Writing notes.md")
        #expect(signals?.startedAt == Date(timeIntervalSince1970: 1))
        #expect(signals?.lastActivityAt == Date(timeIntervalSince1970: 5))
        #expect(signals?.editedFiles.files.map(\.path) == ["/repo/notes.md"])
    }

    @Test func tracksActivityPlanAndSummary() {
        let todo = #"{"todos":[{"content":"Read","status":"completed"},{"content":"Fix","status":"in_progress"}]}"#
        let working = fold.signals(for: [
            event(1, .userPrompt("Ship it")),
            event(2, .toolUse(toolName: "TodoWrite", toolInputJSON: todo)),
            event(3, .toolUse(toolName: "Bash", toolInputJSON: #"{"command":"swift test\nmore"}"#)),
        ])["A"]
        #expect(working?.plan.map(\.title) == ["Read", "Fix"])
        #expect(working?.plan.map(\.status) == [.completed, .inProgress])
        #expect(working?.currentActivity == "Running swift test")

        let reading = fold.signals(for: [event(1, .userPrompt("Ship it"))])["A"]
        #expect(reading?.currentActivity == "Reading your message")

        let stopped = fold.signals(for: [
            event(1, .toolUse(toolName: "Read", toolInputJSON: nil)),
            event(2, .assistantMessage("Shipped **v2**.")),
            event(3, .stop(reason: nil)),
        ])["A"]
        #expect(stopped?.currentActivity == nil)
        #expect(stopped?.lastSummary == "Shipped v2.")

        let ended = fold.signals(for: [
            event(1, .toolUse(toolName: "Read", toolInputJSON: nil)),
            event(2, .sessionEnd),
        ])["A"]
        #expect(ended?.currentActivity == nil)

        // A plan update with no steps keeps the last plan.
        let kept = fold.signals(for: [
            event(1, .plan([AgentHomePlanStep(title: "Keep", status: .pending)])),
            event(2, .toolUse(toolName: "TodoWrite", toolInputJSON: #"{"todos":[]}"#)),
        ])["A"]
        #expect(kept?.plan.map(\.title) == ["Keep"])
    }

    @Test func keepsTerminalsApart() {
        let signals = fold.signals(for: [
            event(1, .userPrompt("One"), terminal: "A"),
            event(2, .userPrompt("Two"), terminal: "B"),
            event(3, .sessionStart, terminal: "B"),
            event(4, .other, terminal: "A", updated: 9),
        ])
        #expect(signals["A"]?.sessionTitle == "One")
        #expect(signals["A"]?.lastActivityAt == Date(timeIntervalSince1970: 9))
        #expect(signals["B"]?.sessionTitle == nil)
        #expect(signals["B"]?.startedAt == Date(timeIntervalSince1970: 3))
    }
}
