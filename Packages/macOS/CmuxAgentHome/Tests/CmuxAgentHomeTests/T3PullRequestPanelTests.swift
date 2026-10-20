import Foundation
import Testing
@testable import CmuxAgentHome

@Suite struct T3PullRequestPanelTests {
    func pullRequest(
        _ number: Int, head: String, base: String = "main", state: String = "open", linkedMinutesAgo: Double = 0,
        repository: String = "jagadhis/oorva-app"
    ) -> T3Thread.PullRequest {
        T3Thread.PullRequest(
            repository: repository, number: number, linkedAt: Date(timeIntervalSince1970: 1_000_000 - linkedMinutesAgo * 60),
            title: "PR \(number)", state: state, headBranch: head, baseBranch: base
        )
    }

    func thread(_ id: String, _ pullRequests: [T3Thread.PullRequest]) -> T3Thread {
        T3Thread(id: id, projectId: "p", projectName: "p", title: id, provider: "claudeAgent", pullRequests: pullRequests)
    }

    @Test func pullRequestsBasedOnEachOtherFormAChainBottomFirst() {
        let chains = T3PullRequestPanel.chains(for: [
            thread("main", [pullRequest(1, head: "feat/a", linkedMinutesAgo: 30)]),
            thread("handoff", [
                pullRequest(3, head: "feat/c", base: "feat/b", linkedMinutesAgo: 10),
                pullRequest(2, head: "feat/b", base: "feat/a", linkedMinutesAgo: 20),
            ]),
            thread("other", [pullRequest(9, head: "fix/x", state: "merged", linkedMinutesAgo: 1)]),
        ])
        #expect(chains.count == 2)
        // Chains with open pull requests come first, though the merged one was linked last.
        #expect(chains[0].entries.map(\.pullRequest.number) == [1, 2, 3])
        #expect(chains[0].entries.map(\.depth) == [0, 1, 2])
        #expect(chains[0].entries.map(\.threadId) == ["main", "handoff", "handoff"])
        #expect(chains[0].isStack)
        #expect(chains[1].entries.map(\.pullRequest.number) == [9])
    }

    @Test func aPullRequestLinkedTwiceShowsOnceWithTheLatestThread() {
        let chains = T3PullRequestPanel.chains(for: [
            thread("main", [pullRequest(1, head: "feat/a", linkedMinutesAgo: 30)]),
            thread("handoff", [pullRequest(1, head: "feat/a", linkedMinutesAgo: 5)]),
        ])
        #expect(chains.flatMap(\.entries).map(\.threadId) == ["handoff"])
    }

    @Test func sameBranchNamesInOtherRepositoriesDoNotChain() {
        let chains = T3PullRequestPanel.chains(for: [
            thread("main", [
                pullRequest(1, head: "feat/a"),
                pullRequest(2, head: "feat/b", base: "feat/a", repository: "jagadhis/other"),
            ]),
        ])
        #expect(chains.count == 2)
    }

    @Test func pullRequestsBasedOnEachOtherInALoopShowOnce() {
        let chains = T3PullRequestPanel.chains(for: [
            thread("main", [pullRequest(1, head: "feat/a", base: "feat/b"), pullRequest(2, head: "feat/b", base: "feat/a")]),
        ])
        #expect(chains.count == 1)
        #expect(chains[0].entries.map(\.pullRequest.number).sorted() == [1, 2])
    }

    @Test func nextStepFollowsT3sOrder() {
        var pr = pullRequest(1, head: "feat/a")
        pr.mergeability = "mergeable"
        pr.checksState = "passing"
        #expect(pr.nextStep == .merge)
        pr.reviewDecision = "review-required"
        #expect(pr.nextStep == nil)
        pr.reviewDecision = "approved"
        pr.checksState = "pending"
        #expect(pr.nextStep == nil)
        pr.checksState = "failing"
        #expect(pr.nextStep == .fixChecks)
        pr.isDraft = true
        #expect(pr.nextStep == .markReady)
        pr.mergeability = "conflicting"
        #expect(pr.nextStep == .resolveConflicts)
        pr.state = "merged"
        #expect(pr.nextStep == nil)
    }

    @Test func chatStepsCarryAPrompt() {
        var pr = pullRequest(42, head: "feat/a", base: "develop")
        pr.url = URL(string: "https://github.com/jagadhis/oorva-app/pull/42")
        let prompt = T3PullRequestNextStep.resolveConflicts.prompt(for: pr) ?? ""
        #expect(prompt.contains("https://github.com/jagadhis/oorva-app/pull/42"))
        #expect(prompt.contains("`develop`"))
        #expect(T3PullRequestNextStep.fixChecks.prompt(for: pr)?.contains("gh pr checks 42 --repo jagadhis/oorva-app") == true)
        #expect(T3PullRequestNextStep.merge.prompt(for: pr) == nil)
        #expect(T3PullRequestNextStep.fixChecks.startsChat)
        #expect(!T3PullRequestNextStep.markReady.startsChat)
    }
}
