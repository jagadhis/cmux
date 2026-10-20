import Foundation
import Testing
@testable import CmuxAgentHome

@Suite struct T3ChatLinksTests {
    @Test func readsTheLinkedThreadAfterTheSidecarsRedirect() throws {
        // What the browser shows once `/t3/<id>?…` has redirected to the session page.
        let redirected = try #require(URL(string:
            "http://127.0.0.1:7739/tok/s/t3-bWNwOmFiYw?transparent=1&workspace=6F2A3B1C-1D2E-4F5A-8B9C-0D1E2F3A4B5C&via=link&thread=mcp%3Aabc"))
        #expect(T3ChatLinks.isChatURL(redirected))
        #expect(T3ChatLinks.linkedThreadId(in: redirected) == "mcp:abc")
        // Before the redirect too.
        let direct = try #require(URL(string: "http://127.0.0.1:7739/tok/t3/mcp%3Aabc?via=link&thread=mcp%3Aabc"))
        #expect(T3ChatLinks.linkedThreadId(in: direct) == "mcp:abc")
    }

    @Test func ignoresChatsCmuxNavigatedAndOtherPages() throws {
        let opened = try #require(URL(string: "http://127.0.0.1:7739/tok/s/t3-bWNwOmFiYw?transparent=1"))
        #expect(T3ChatLinks.isChatURL(opened))
        #expect(T3ChatLinks.linkedThreadId(in: opened) == nil)
        let github = try #require(URL(string: "https://github.com/a/b/pull/1?via=link&thread=x"))
        #expect(!T3ChatLinks.isChatURL(github))
        #expect(T3ChatLinks.linkedThreadId(in: github) == nil)
        let terminalChat = try #require(URL(string: "http://127.0.0.1:7739/tok/s/t-abc?via=link&thread=x"))
        #expect(T3ChatLinks.linkedThreadId(in: terminalChat) == nil)
    }
}
