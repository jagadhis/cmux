import Foundation
import Testing
@testable import CmuxAgentHome

@Suite struct GitHubPullRequestInboxTests {
    func node(
        _ number: Int, repo: String = "phas-io/Nebula", draft: Bool = false, decision: String? = "REVIEW_REQUIRED",
        checks: String? = "SUCCESS", mergeable: String = "MERGEABLE", updated: String = "2026-10-20T08:00:00Z",
        reviews: [[String: Any]] = []
    ) -> [String: Any] {
        var node: [String: Any] = [
            "number": number, "title": "PR \(number)", "url": "https://github.com/\(repo)/pull/\(number)",
            "isDraft": draft, "createdAt": "2026-10-19T08:00:00Z", "updatedAt": updated, "headRefName": "fix/\(number)",
            "repository": ["nameWithOwner": repo], "author": ["login": "someone"],
            "mergeable": mergeable, "additions": 10, "deletions": 2, "comments": ["totalCount": 3],
            "commits": ["nodes": [["commit": ["statusCheckRollup": checks.map { ["state": $0] } as Any]]]],
            "latestReviews": ["nodes": reviews],
        ]
        if let decision { node["reviewDecision"] = decision }
        return node
    }

    func response(review: [[String: Any]], mine: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "data": [
                "viewer": ["login": "jagadhis"],
                "review": ["issueCount": 23, "nodes": review],
                "mine": ["issueCount": mine.count, "nodes": mine],
            ],
        ])
    }

    @Test func parsesBothListsWithStatus() throws {
        let data = try response(
            review: [node(2525, reviews: [["author": ["login": "jagadhis"], "state": "COMMENTED"]])],
            mine: [node(2527, checks: "PENDING")]
        )
        let inbox = try #require(GitHubPullRequestInbox.parse(data))
        #expect(inbox.viewer == "jagadhis")
        #expect(inbox.toReviewTotal == 23)
        let pr = try #require(inbox.toReview.first)
        #expect(pr.key == "phas-io/Nebula#2525")
        #expect(pr.url == "https://github.com/phas-io/Nebula/pull/2525")
        #expect(pr.checks == .passing)
        #expect(pr.review == .required)
        #expect(pr.comments == 3)
        #expect(pr.viewerReviewState == "COMMENTED")
        #expect(pr.updatedAt == T3CodeStateReader.date("2026-10-20T08:00:00Z"))
        #expect(inbox.mine.first?.checks == .running)
    }

    @Test func ownPullRequestsSortByWhatNeedsDoing() throws {
        let data = try response(review: [], mine: [
            node(1, updated: "2026-10-20T09:00:00Z"),
            node(2, decision: "APPROVED"),
            node(3, checks: "FAILURE"),
            node(4, mergeable: "CONFLICTING"),
            node(5, draft: true),
            node(6, decision: "CHANGES_REQUESTED"),
        ])
        let inbox = try #require(GitHubPullRequestInbox.parse(data))
        #expect(inbox.mine.map(\.number) == [4, 3, 6, 2, 1, 5])
        #expect(inbox.mine.map(\.nextStep) == [.fixConflicts, .fixChecks, .addressReview, .merge, .awaitingReview, .draft])
        #expect(inbox.mine.filter { $0.nextStep.isActionable }.count == 4)
    }

    @Test func approvedButStillRunningIsNotReadyToMerge() {
        let pr = GitHubPullRequest(url: "u", repository: "r", number: 1, title: "t", checks: .running, review: .approved)
        #expect(pr.nextStep == .checksRunning)
    }

    @Test func errorResponsesParseToNil() {
        #expect(GitHubPullRequestInbox.parse(Data(#"{"errors":[{"message":"Bad credentials"}]}"#.utf8)) == nil)
        #expect(GitHubPullRequestInbox.parse(Data("not json".utf8)) == nil)
    }
}
