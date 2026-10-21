import CmuxAgentHome
import CmuxFoundation
import Foundation

struct GitHubCLIError: Error, Equatable {
    let message: String
}

/// Runs the `gh` CLI with the account it's signed in to.
///
/// Goes through cmux's ``CommandRunner``, which drains stdout and stderr
/// concurrently and terminates `gh` at the deadline or when the awaiting task
/// is cancelled, so a hung `gh` can't leave Agent Home loading forever.
/// GUI apps don't get the shell's PATH, so `gh` is looked up in the usual places.
struct GitHubCLI: Sendable {
    static let candidatePaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    static var executable: String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// How long a `gh` call may take before it's stopped.
    static let defaultTimeout: TimeInterval = 45

    private let runner: any CommandRunning

    init(runner: any CommandRunning = CommandRunner()) {
        self.runner = runner
    }

    /// Runs `gh` with arguments and returns its output, or its first error line.
    ///
    /// Pass `changesGitHub` for a merge, comment or similar: one stopped at the
    /// deadline may already have gone through, and the error says so.
    func run(_ arguments: [String], timeout: TimeInterval = GitHubCLI.defaultTimeout, changesGitHub: Bool = false) async -> Result<String, GitHubCLIError> {
        let result: CommandResult
        switch await launch(arguments, timeout: timeout) {
        case .success(let launched): result = launched
        case .failure(let error): return .failure(error)
        }
        if result.timedOut { return .failure(GitHubCLIError(message: changesGitHub ? Self.timedOutChangeMessage : Self.failedMessage)) }
        guard result.exitStatus == 0 else {
            let detail = Self.firstLine(result.stderr)
            return .failure(GitHubCLIError(message: detail.isEmpty ? Self.failedMessage : detail))
        }
        return .success(result.stdout ?? "")
    }

    /// Fetches the inbox, trying once more when GitHub has a hiccup (its search API sometimes returns 502).
    func fetchInbox() async -> Result<GitHubPullRequestInbox, GitHubCLIError> {
        let first = await fetchInboxOnce()
        guard case .failure = first, Self.executable != nil, !Task.isCancelled else { return first }
        // A genuine pause before the one retry, not a wait for some state.
        try? await Task.sleep(for: .seconds(2))
        return await fetchInboxOnce()
    }

    private func fetchInboxOnce() async -> Result<GitHubPullRequestInbox, GitHubCLIError> {
        let result: CommandResult
        switch await launch([
            "api", "graphql",
            "-F", "review=\(GitHubPullRequestInbox.reviewSearch)",
            "-F", "mine=\(GitHubPullRequestInbox.mineSearch)",
            "-f", "query=\(GitHubPullRequestInbox.query)",
        ], timeout: Self.defaultTimeout) {
        case .success(let launched): result = launched
        case .failure(let error): return .failure(error)
        }
        if let inbox = GitHubPullRequestInbox.parse(Data((result.stdout ?? "").utf8)) { return .success(inbox) }
        let detail = Self.firstLine(result.stderr)
        if detail.contains("auth login") || detail.contains("401") {
            return .failure(GitHubCLIError(message: String(
                localized: "agentHome.prs.signIn",
                defaultValue: "Sign in to GitHub with gh auth login to see your pull requests."
            )))
        }
        return .failure(GitHubCLIError(message: detail.isEmpty
            ? Self.failedMessage
            : String(localized: "agentHome.prs.failedDetail", defaultValue: "Couldn't reach GitHub: \(detail)")))
    }

    /// Starts `gh` and waits for it; fails when it's missing, can't start, or runs past `timeout`.
    private func launch(_ arguments: [String], timeout: TimeInterval) async -> Result<CommandResult, GitHubCLIError> {
        guard let gh = Self.executable else {
            return .failure(GitHubCLIError(message: String(
                localized: "agentHome.prs.noGh",
                defaultValue: "Install the GitHub CLI (brew install gh) and sign in with gh auth login to see your pull requests."
            )))
        }
        // `env` sets gh's variables without a second process-running path.
        let result = await runner.run(
            directory: NSHomeDirectory(),
            executable: "/usr/bin/env",
            arguments: ["GH_PROMPT_DISABLED=1", "NO_COLOR=1", gh] + arguments,
            timeout: timeout
        )
        if let error = result.executionError { return .failure(GitHubCLIError(message: error)) }
        return .success(result)
    }

    private static var timedOutChangeMessage: String {
        String(localized: "agentHome.prs.timedOut", defaultValue: "GitHub didn't answer in time. The change may still have gone through; check the pull request before trying again.")
    }

    private static var failedMessage: String {
        String(localized: "agentHome.prs.failed", defaultValue: "Couldn't reach GitHub. Will try again shortly.")
    }

    private static func firstLine(_ text: String?) -> String {
        text?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}
