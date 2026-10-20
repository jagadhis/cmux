import Testing
@testable import CmuxAgentHome

@Suite struct AgentHomePlanParserTests {
    @Test func parsesClaudeTodoWrite() {
        let json = #"{"todos":[{"content":"Switch relay to Bulbul v4 Flash","status":"completed","activeForm":"Switching"},{"content":"Canary deploy","status":"in_progress"},{"content":"Docs","status":"pending"},{"content":"  ","status":"pending"}]}"#
        let steps = AgentHomePlanParser.steps(fromToolInputJSON: json)
        #expect(steps.map(\.title) == ["Switch relay to Bulbul v4 Flash", "Canary deploy", "Docs"])
        #expect(steps.map(\.status) == [.completed, .inProgress, .pending])
    }

    @Test func parsesBareArraysAndAlternateKeys() {
        let json = #"[{"text":"Read the API","state":"done"},{"title":"Wire buttons","state":"active"}]"#
        #expect(AgentHomePlanParser.steps(fromToolInputJSON: json).map(\.status) == [.completed, .inProgress])
    }

    @Test func emptyOrInvalidInputHasNoSteps() {
        #expect(AgentHomePlanParser.steps(fromToolInputJSON: nil).isEmpty)
        #expect(AgentHomePlanParser.steps(fromToolInputJSON: "nope").isEmpty)
        #expect(AgentHomePlanParser.steps(fromToolInputJSON: #"{"other":1}"#).isEmpty)
    }

    @Test func permissionSummaryShowsTheCommand() {
        let bash = AgentHomePermissionSummary.summary(
            toolName: "Bash",
            toolInputJSON: #"{"command":"fly deploy --app oorva-voice-relay --strategy canary\necho done","description":"Deploy"}"#
        )
        #expect(bash == "fly deploy --app oorva-voice-relay --strategy canary")
        let edit = AgentHomePermissionSummary.summary(
            toolName: "Edit",
            toolInputJSON: #"{"file_path":"/repo/services/voice/relay.ts"}"#,
            workingDirectory: "/repo"
        )
        #expect(edit == "Editing services/voice/relay.ts")
    }
}
