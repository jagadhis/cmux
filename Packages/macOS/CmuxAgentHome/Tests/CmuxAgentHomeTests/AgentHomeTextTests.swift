import Testing
@testable import CmuxAgentHome

@Suite struct AgentHomeTextTests {
    @Test func titleIsTheFirstLineTrimmed() {
        #expect(AgentHomeText.title(fromPrompt: "\n  Deploy the relay  \nthen watch logs") == "Deploy the relay")
        #expect(AgentHomeText.title(fromPrompt: "   \n ") == nil)
        let long = AgentHomeText.title(fromPrompt: String(repeating: "word ", count: 30), maximumLength: 20)
        #expect(long?.count ?? 0 <= 20)
        #expect(long?.hasSuffix("…") == true)
    }

    @Test func summaryIsTheFirstParagraphAsPlainText() {
        let reply = """
        All three steps are done, but **task list tools** weren't available, so I used `chat`.

        1. **Create notes.md:** done.
        """
        #expect(AgentHomeText.summary(fromMarkdown: reply) == "All three steps are done, but task list tools weren't available, so I used chat.")
    }

    @Test func summarySkipsHeadingsAndFences() {
        let reply = "## Result\n\n```\ncode\n```\n\nShipped it."
        #expect(AgentHomeText.summary(fromMarkdown: reply) == "Result")
        #expect(AgentHomeText.summary(fromMarkdown: "```\nonly code\n```") == "only code")
        #expect(AgentHomeText.summary(fromMarkdown: "  ") == nil)
    }
}
