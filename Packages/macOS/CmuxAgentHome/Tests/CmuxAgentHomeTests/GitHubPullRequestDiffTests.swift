import Foundation
import Testing
@testable import CmuxAgentHome

@Suite struct GitHubPullRequestDiffTests {
    @Test func splitsHunksWithLineNumbers() throws {
        let patch = """
            @@ -10,4 +10,5 @@ fun lookup() {
             val a = 1
            -val b = 2
            +val b = 3
            +val c = 4
             return a
            @@ -40,2 +41,2 @@
            -old
            +new
            \\ No newline at end of file
            """
        let hunks = GitHubDiffHunk.parse(patch)
        #expect(hunks.count == 2)
        #expect(hunks[0].header == "@@ -10,4 +10,5 @@ fun lookup() {")
        let first = hunks[0].lines
        #expect(first.map(\.kind) == [.context, .deletion, .addition, .addition, .context])
        #expect(first.map(\.oldNumber) == [10, 11, nil, nil, 12])
        #expect(first.map(\.newNumber) == [10, nil, 11, 12, 13])
        #expect(first[1].text == "val b = 2")
        #expect(hunks[1].lines.map(\.kind) == [.deletion, .addition, .noNewline])
        #expect(hunks[1].lines[0].oldNumber == 40)
        #expect(hunks[1].lines[1].newNumber == 41)
    }

    @Test func aTrailingNewlineAddsNoLine() {
        let hunks = GitHubDiffHunk.parse("@@ -1 +1 @@\n-a\n+b\n")
        #expect(hunks[0].lines.count == 2)
    }

    @Test func readsTheRESTFilesListAndOrdersByFolder() throws {
        let json = """
            [{"filename":"src/b/z.kt","status":"modified","additions":3,"deletions":1,"patch":"@@ -1 +1 @@\\n-a\\n+b"},
             {"filename":"README.md","status":"added","additions":10,"deletions":0},
             {"filename":"src/a/new.kt","previous_filename":"src/a/old.kt","status":"renamed","additions":0,"deletions":0},
             {"filename":"src/b/a.kt","status":"removed","additions":0,"deletions":4}]
            """
        let objects = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        let files = objects.compactMap(GitHubPullRequestFile.fromREST)
        #expect(files.count == 4)
        #expect(files[1].patch == nil)
        #expect(files[1].hunks.isEmpty)
        #expect(files[2].previousPath == "src/a/old.kt")
        #expect(files[2].status == .renamed)
        #expect(GitHubPullRequestFile.reviewOrder(files).map(\.path) == ["README.md", "src/a/new.kt", "src/b/a.kt", "src/b/z.kt"])
    }
}
