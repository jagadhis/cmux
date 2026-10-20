import Foundation
import Testing
@testable import CmuxAgentHome

@Suite struct GitHubPullRequestDetailTests {
    let ref = GitHubPullRequestRef(repository: "acme/widgets", number: 42)

    func response(state: String = "OPEN", isDraft: Bool = false, mergeable: String = "MERGEABLE", autoMerge: Bool = false, squashOnly: Bool = false) -> Data {
        let json = """
            {"data":{"viewer":{"login":"me"},"repository":{
              "mergeCommitAllowed":\(!squashOnly),"squashMergeAllowed":true,"rebaseMergeAllowed":false,
              "pullRequest":{"number":42,"title":"Fix the thing","url":"https://github.com/acme/widgets/pull/42","state":"\(state)","isDraft":\(isDraft),
                "bodyHTML":"<p>Body</p>","author":{"__typename":"User","login":"ana","avatarUrl":"https://avatars.example/ana"},
                "createdAt":"2026-10-01T10:00:00Z","updatedAt":"2026-10-03T10:00:00Z","mergedAt":null,"closedAt":null,
                "headRefName":"fix/thing","baseRefName":"main","headRefOid":"abc123","additions":12,"deletions":3,"changedFiles":2,
                "mergeable":"\(mergeable)","mergeStateStatus":"BEHIND","reviewDecision":"CHANGES_REQUESTED",
                "autoMergeRequest":\(autoMerge ? "{\"enabledAt\":\"2026-10-03T10:00:00Z\"}" : "null"),
                "labels":{"nodes":[{"name":"bug","color":"d73a4a"}]},
                "reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"User","login":"bo"}},{"requestedReviewer":{"__typename":"Team","name":"core"}}]},
                "latestOpinionatedReviews":{"nodes":[
                  {"author":{"__typename":"User","login":"cy"},"state":"APPROVED","submittedAt":"2026-10-01T12:00:00Z"},
                  {"author":{"__typename":"User","login":"di"},"state":"CHANGES_REQUESTED","submittedAt":"2026-10-03T09:00:00Z"}]},
                "commits":{"nodes":[
                  {"commit":{"oid":"111aaaa","messageHeadline":"First","committedDate":"2026-10-01T11:00:00Z","author":{"name":"Ana","user":{"login":"ana"}},"statusCheckRollup":null}},
                  {"commit":{"oid":"abc123","messageHeadline":"Second","committedDate":"2026-10-02T11:00:00Z","author":{"name":"Ana","user":null},
                    "statusCheckRollup":{"contexts":{"nodes":[
                      {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://ci/1","isRequired":true,"checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},
                      {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":null,"isRequired":false,"checkSuite":null},
                      {"__typename":"CheckRun","name":"deploy","status":"WAITING","conclusion":null,"detailsUrl":null,"isRequired":false,"checkSuite":null},
                      {"__typename":"CheckRun","name":"docs","status":"COMPLETED","conclusion":"SKIPPED","detailsUrl":null,"isRequired":false,"checkSuite":null},
                      {"__typename":"StatusContext","context":"ci/legacy","state":"PENDING","targetUrl":"https://ci/2","description":"Waiting","isRequired":false}]}}}}]},
                "comments":{"nodes":[
                  {"id":"c1","url":"https://github.com/acme/widgets/pull/42#c1","bodyHTML":"<p>One</p>","createdAt":"2026-10-01T13:00:00Z","author":{"__typename":"User","login":"bo"}},
                  {"id":"c2","url":null,"bodyHTML":"<p>Two</p>","createdAt":"2026-10-01T14:00:00Z","author":{"__typename":"Bot","login":"ci-helper"}}]},
                "reviews":{"nodes":[
                  {"id":"r1","url":null,"state":"APPROVED","bodyHTML":"","submittedAt":"2026-10-01T12:00:00Z","author":{"__typename":"User","login":"cy"}},
                  {"id":"r2","url":null,"state":"COMMENTED","bodyHTML":"<p> </p>","submittedAt":"2026-10-01T12:30:00Z","author":{"__typename":"User","login":"cy"}}]},
                "reviewThreads":{"nodes":[{"id":"t1","path":"src/a.kt","line":7,"isResolved":false,"isOutdated":false,
                  "comments":{"nodes":[{"id":"tc1","url":null,"bodyHTML":"<p>Why?</p>","createdAt":"2026-10-03T09:00:00Z","diffHunk":"@@ -1,2 +1,2 @@\\n-a\\n+b","author":{"__typename":"User","login":"di"}}]}}]}
              }}}}
            """
        return Data(json.utf8)
    }

    @Test func readsTheDetail() throws {
        let detail = try #require(GitHubPullRequestDetail.parse(graphQL: response(), ref: ref))
        #expect(detail.title == "Fix the thing")
        #expect(detail.state == .open)
        #expect(detail.headBranch == "fix/thing")
        #expect(detail.baseBranch == "main")
        #expect(detail.additions == 12)
        #expect(detail.isBehind)
        #expect(detail.reviewDecision == "changes-requested")
        #expect(detail.labels.map(\.name) == ["bug"])
        #expect(detail.viewer == "me")
        #expect(detail.allowedMergeMethods == [.merge, .squash])
        // Commit author falls back to the git name when GitHub has no user.
        #expect(detail.commits.map(\.author) == ["ana", "Ana"])
        // Bots read as name[bot].
        #expect(detail.comments.last?.author?.login == "ci-helper[bot]")
        #expect(detail.comments.last?.author?.isBot == true)
        #expect(detail.reviewThreads.first?.diffHunk == "@@ -1,2 +1,2 @@\n-a\n+b")
    }

    @Test func reviewersCarryTheirLatestVerdictAndStaleness() throws {
        let detail = try #require(GitHubPullRequestDetail.parse(graphQL: response(), ref: ref))
        let byLogin = Dictionary(uniqueKeysWithValues: detail.reviewers.map { ($0.actor.login, $0) })
        // cy approved before the last commit: stale. di asked for changes after it.
        #expect(byLogin["cy"]?.verdict == .approved)
        #expect(byLogin["cy"]?.isStale == true)
        #expect(byLogin["di"]?.verdict == .changesRequested)
        #expect(byLogin["di"]?.isStale == false)
        // Requested reviewers without a verdict, teams included.
        #expect(byLogin["bo"]?.verdict == nil)
        #expect(byLogin["@core"] != nil)
    }

    @Test func checksUseT3sStatuses() throws {
        let detail = try #require(GitHubPullRequestDetail.parse(graphQL: response(), ref: ref))
        #expect(detail.checks.map(\.status) == [.failure, .success, .actionRequired, .skipped, .pending])
        #expect(detail.checks[0].workflow == "CI")
        #expect(detail.checks[0].isRequired)
        #expect(detail.checksState == .failing)
        let summary = detail.checksSummary
        #expect(summary.failing == 2 && summary.running == 1 && summary.passed == 1 && summary.skipped == 1)
    }

    @Test func primaryActionFollowsT3sOrder() throws {
        #expect(GitHubPullRequestDetail.parse(graphQL: response(), ref: ref)?.primaryAction == .merge(.merge))
        #expect(GitHubPullRequestDetail.parse(graphQL: response(squashOnly: true), ref: ref)?.primaryAction == .merge(.squash))
        #expect(GitHubPullRequestDetail.parse(graphQL: response(autoMerge: true), ref: ref)?.primaryAction == .autoMergeEnabled)
        #expect(GitHubPullRequestDetail.parse(graphQL: response(isDraft: true), ref: ref)?.primaryAction == .readyForReview)
        #expect(GitHubPullRequestDetail.parse(graphQL: response(isDraft: true, mergeable: "CONFLICTING"), ref: ref)?.primaryAction == .resolveConflicts)
        #expect(GitHubPullRequestDetail.parse(graphQL: response(state: "MERGED"), ref: ref)?.primaryAction == .state(.merged))
    }

    @Test func timelineFoldsCommentRunsAndSkipsEmptyReviews() throws {
        let detail = try #require(GitHubPullRequestDetail.parse(graphQL: response(), ref: ref))
        let oldestFirst = GitHubPullRequestTimeline.entries(for: detail, newestFirst: false)
        // opened, first commit, approval, then two comments folded, then the second commit.
        #expect(oldestFirst.map(\.id) == ["opened", "commit-111aaaa", "review-r1", "comments-c1", "commit-abc123"])
        if case .comments(let run) = oldestFirst[3] { #expect(run.map(\.id) == ["c1", "c2"]) } else { Issue.record("expected a comment run") }
        if case .review(_, let stale) = oldestFirst[2] { #expect(stale) } else { Issue.record("expected a review") }
        #expect(GitHubPullRequestTimeline.entries(for: detail).map(\.id) == oldestFirst.map(\.id).reversed())
    }

    @Test func refsReadPullRequestURLs() throws {
        let url = try #require(URL(string: "https://github.com/acme/widgets/pull/42/files"))
        #expect(GitHubPullRequestRef(url: url) == ref)
        #expect(GitHubPullRequestRef(url: try #require(URL(string: "https://github.com/acme/widgets/issues/42"))) == nil)
        #expect(ref.id == "acme/widgets#42")
    }
}
