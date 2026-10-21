import AppKit
import CmuxAgentHome
import Foundation
import Observation

/// What a T3 task's "Linked pull requests" panel does: open a pull request
/// beside the task's terminal, and run the row's next step.
///
/// Resolve and Fix start a new chat with a prompt (as T3's do); Ready and
/// Merge run `gh` with the account it's signed in to. T3 re-reads each linked
/// pull request about once a minute, so the row catches up shortly after.
@MainActor
@Observable
final class AgentHomeT3PullRequestActions {
    static let shared = AgentHomeT3PullRequestActions()

    /// Pull requests with a step in flight, by `owner/name#number`.
    private(set) var pending: Set<String> = []
    /// The last outcome per pull request, cleared after a few seconds.
    private(set) var outcomes: [String: Outcome] = [:]

    struct Outcome: Equatable {
        var message: String
        var failed: Bool
    }

    private let gitHub = GitHubCLI()

    private init() {}

    /// Opens a pull request in a browser split beside the task's terminal,
    /// signed in to GitHub when a browser profile is.
    func open(_ pullRequest: T3Thread.PullRequest, inWorkspace workspaceId: UUID?, tabManager: TabManager) {
        guard let url = pullRequest.url else { return }
        guard let workspaceId, let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
            NSWorkspace.shared.open(url)
            return
        }
        // Reuse a browser already showing this pull request.
        if let existing = workspace.panels.values.compactMap({ $0 as? BrowserPanel }).first(where: { $0.currentURL?.absoluteString.hasPrefix(url.absoluteString) == true }) {
            workspace.focusPanel(existing.id)
            return
        }
        let anchor = workspace.panels.values.first { !($0 is BrowserPanel) }?.id ?? workspace.focusedPanelId
        AgentHomePullRequestsModel.shared.openGitHubSplit(url, in: workspace, beside: anchor, orientation: .vertical)
    }

    /// Runs a step that acts on GitHub directly (Ready or Merge), through the
    /// same `gh` commands as the pull request detail view's actions.
    func run(_ step: T3PullRequestNextStep, on pullRequest: T3Thread.PullRequest) {
        let key = pullRequest.key
        guard !pending.contains(key), !step.startsChat else { return }
        pending.insert(key)
        outcomes[key] = nil
        let ref = GitHubPullRequestRef(repository: pullRequest.repository, number: pullRequest.number)
        Task {
            let action: AgentHomePullRequestDetailModel.Action = step == .merge
                ? .merge(await Self.mergeMethod(repository: ref.repository, gitHub: gitHub))
                : .ready
            let result = await gitHub.run(AgentHomePullRequestDetailModel.arguments(for: action, ref: ref), changesGitHub: true)
            pending.remove(key)
            switch result {
            case .success:
                show(key, Outcome(
                    message: step == .merge
                        ? String(localized: "agentHome.t3.pr.merged", defaultValue: "Merged. T3 shows it within a minute.")
                        : String(localized: "agentHome.t3.pr.markedReady", defaultValue: "Marked ready for review."),
                    failed: false
                ))
            case .failure(let error):
                show(key, Outcome(message: error.message, failed: true))
            }
        }
    }

    private func show(_ key: String, _ outcome: Outcome) {
        outcomes[key] = outcome
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if self?.outcomes[key] == outcome { self?.outcomes[key] = nil }
        }
    }

    /// The first merge method the repository allows, in T3's order of preference.
    static func mergeMethod(repository: String, gitHub: GitHubCLI) async -> GitHubPullRequestDetail.MergeMethod {
        guard case .success(let text) = await gitHub.run([
            "repo", "view", repository, "--json", "mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed",
        ]),
            let allowed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Bool]
        else { return .merge }
        if allowed["mergeCommitAllowed"] == true { return .merge }
        if allowed["squashMergeAllowed"] == true { return .squash }
        if allowed["rebaseMergeAllowed"] == true { return .rebase }
        return .merge
    }
}
