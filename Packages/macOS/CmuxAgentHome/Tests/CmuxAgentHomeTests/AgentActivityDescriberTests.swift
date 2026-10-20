import Testing
@testable import CmuxAgentHome

@Suite struct AgentActivityDescriberTests {
    @Test func filePathsAreRelativeToTheTask() {
        let line = AgentActivityDescriber.describe(
            toolName: "Read",
            toolInputJSON: #"{"file_path":"/Users/jags/projects/oorva-app/services/voice/relay.ts"}"#,
            workingDirectory: "/Users/jags/projects/oorva-app"
        )
        #expect(line == "Reading services/voice/relay.ts")
    }

    @Test func filePathsOutsideTheTaskShowTheirLastTwoComponents() {
        let line = AgentActivityDescriber.describe(toolName: "Edit", toolInputJSON: #"{"file_path":"/etc/nginx/conf.d/site.conf"}"#)
        #expect(line == "Editing conf.d/site.conf")
    }

    @Test func bashPrefersTheDescription() {
        let described = AgentActivityDescriber.describe(
            toolName: "Bash",
            toolInputJSON: #"{"command":"bun test services/voice","description":"Run the voice tests"}"#
        )
        let bare = AgentActivityDescriber.describe(toolName: "Bash", toolInputJSON: #"{"command":"git status\ngit diff"}"#)
        #expect(described == "Run the voice tests")
        #expect(bare == "Running git status")
    }

    @Test func codexShellCommandArrays() {
        let line = AgentActivityDescriber.describe(toolName: "shell", toolInputJSON: #"{"command":["rg","-n","relay"]}"#)
        #expect(line == "Running rg -n relay")
    }

    @Test func searchesAndWeb() {
        #expect(AgentActivityDescriber.describe(toolName: "Grep", toolInputJSON: #"{"pattern":"withFallback"}"#) == #"Searching for "withFallback""#)
        #expect(AgentActivityDescriber.describe(toolName: "WebFetch", toolInputJSON: #"{"url":"https://fly.io/docs/x"}"#) == "Reading fly.io")
    }

    @Test func mcpAndUnknownTools() {
        #expect(AgentActivityDescriber.describe(toolName: "mcp__github__create_pull_request", toolInputJSON: nil) == "Using create pull request")
        #expect(AgentActivityDescriber.describe(toolName: "Frobnicate", toolInputJSON: "not json") == "Using Frobnicate")
    }

    @Test func longLinesAreTruncated() {
        let command = String(repeating: "x", count: 200)
        let line = AgentActivityDescriber.describe(toolName: "Bash", toolInputJSON: #"{"command":"\#(command)"}"#)
        #expect(line.count == AgentActivityDescriber.maximumLength)
        #expect(line.hasSuffix("…"))
    }
}
