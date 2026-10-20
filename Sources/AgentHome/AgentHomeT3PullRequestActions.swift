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
        let viewer = AgentHomePullRequestsModel.shared.inbox?.viewer
        Task {
            let profileID = await AgentHomePullRequestsModel.gitHubProfileID(viewer: viewer)
            guard let anchor,
                  workspace.newBrowserSplit(
                      from: anchor,
                      orientation: .vertical,
                      url: url,
                      preferredProfileID: profileID,
                      focus: true
                  ) != nil
            else {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    /// Runs a step that acts on GitHub directly (Ready or Merge).
    func run(_ step: T3PullRequestNextStep, on pullRequest: T3Thread.PullRequest) {
        let key = pullRequest.key
        guard !pending.contains(key) else { return }
        pending.insert(key)
        outcomes[key] = nil
        let repository = pullRequest.repository
        let number = String(pullRequest.number)
        Task {
            let result: Result<String, GitHubCLIError> = await Task.detached(priority: .userInitiated) {
                switch step {
                case .markReady:
                    return GitHubCLI.run(["pr", "ready", number, "--repo", repository])
                case .merge:
                    let method = Self.mergeMethod(repository: repository)
                    return GitHubCLI.run(["pr", "merge", number, "--repo", repository, "--\(method)"])
                case .resolveConflicts, .fixChecks:
                    return .failure(GitHubCLIError(message: "unsupported"))
                }
            }.value
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
    nonisolated static func mergeMethod(repository: String) -> String {
        guard case .success(let text) = GitHubCLI.run([
            "repo", "view", repository, "--json", "mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed",
        ]),
            let data = text.data(using: .utf8),
            let allowed = try? JSONSerialization.jsonObject(with: data) as? [String: Bool]
        else { return "merge" }
        if allowed["mergeCommitAllowed"] == true { return "merge" }
        if allowed["squashMergeAllowed"] == true { return "squash" }
        if allowed["rebaseMergeAllowed"] == true { return "rebase" }
        return "merge"
    }
}

extension GitHubCLI {
    /// Runs `gh` with arguments and returns its output, or its first error line.
    nonisolated static func run(_ arguments: [String]) -> Result<String, GitHubCLIError> {
        guard let gh = executable else {
            return .failure(GitHubCLIError(message: String(
                localized: "agentHome.prs.noGh",
                defaultValue: "Install the GitHub CLI (brew install gh) and sign in with gh auth login to see your pull requests."
            )))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .failure(GitHubCLIError(message: error.localizedDescription))
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = errorText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return .failure(GitHubCLIError(message: detail.isEmpty
                ? String(localized: "agentHome.prs.failed", defaultValue: "Couldn't reach GitHub. Will try again shortly.")
                : detail))
        }
        return .success(String(data: data, encoding: .utf8) ?? "")
    }
}
