import AppKit
import CmuxAgentHome
import Foundation
import Observation
import WebKit

/// The user's GitHub pull requests in Agent Home: the ones waiting on their
/// review and the ones they opened.
///
/// Reads GitHub through the `gh` CLI with the account it's signed in to, every
/// couple of minutes while Agent Home is open. Opening a pull request gives it
/// a workspace: the page in a browser beside a terminal in the matching T3
/// project's folder.
@MainActor
@Observable
final class AgentHomePullRequestsModel {
    static let shared = AgentHomePullRequestsModel()

    private(set) var inbox: GitHubPullRequestInbox?
    private(set) var lastUpdated: Date?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    /// T3 threads linked to pull requests, by `owner/name#number`.
    private(set) var linkedThreads: [String: T3CodeStateReader.PullRequestThread] = [:]
    /// Every T3 project, for matching repositories to folders and for New chat.
    private(set) var projects: [T3CodeStateReader.Project] = []

    /// Each project's GitHub repository from its git origin, by project id.
    private var origins: [String: String] = [:]
    /// The workspace each opened pull request lives in, by URL.
    private var workspaces: [String: UUID] = [:]
    private var pollTask: Task<Void, Never>?

    private static let pollInterval: Duration = .seconds(120)

    // MARK: - Loading

    /// Starts polling GitHub. Safe to call repeatedly.
    func startIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// Reads GitHub and T3 now.
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let local = await Task.detached(priority: .utility) { () -> ([T3CodeStateReader.Project], [String: String], [String: T3CodeStateReader.PullRequestThread]) in
            let reader = T3CodeStateReader()
            let projects = (try? reader.projects()) ?? []
            var origins: [String: String] = [:]
            for project in projects {
                let config = URL(fileURLWithPath: project.root).appendingPathComponent(".git/config")
                if let text = try? String(contentsOf: config, encoding: .utf8),
                   let repository = GitHubRepositoryMatcher.originRepository(gitConfig: text) {
                    origins[project.id] = repository
                }
            }
            return (projects, origins, (try? reader.pullRequestThreads()) ?? [:])
        }.value
        projects = local.0
        origins = local.1
        linkedThreads = local.2

        let result = await Task.detached(priority: .utility) { () -> Result<GitHubPullRequestInbox, GitHubCLIError> in
            GitHubCLI.fetchInbox()
        }.value
        switch result {
        case .success(let fetched):
            if fetched != inbox { inbox = fetched }
            errorMessage = nil
            lastUpdated = Date()
        case .failure(let error):
            errorMessage = error.message
        }
    }

    // MARK: - Lookups

    /// The T3 project whose folder holds a pull request's repository.
    func project(for pullRequest: GitHubPullRequest) -> T3CodeStateReader.Project? {
        GitHubRepositoryMatcher.project(for: pullRequest.repository, in: projects, origins: origins)
    }

    /// Pull requests waiting on the user: review requests, plus their own that need them.
    var attentionCount: Int {
        guard let inbox else { return 0 }
        return inbox.toReview.count + inbox.mine.filter { $0.nextStep.isActionable }.count
    }

    // MARK: - Opening

    /// Opens a pull request in its own workspace: the page in a browser on the
    /// left, a terminal in the matching project's folder on the right.
    func open(_ pullRequest: GitHubPullRequest, tabManager: TabManager) {
        AgentHomeTaskViewState.shared.showsPullRequests = false
        if let existing = workspaces[pullRequest.url], tabManager.tabs.contains(where: { $0.id == existing }) {
            tabManager.focusTab(existing)
            return
        }
        guard let url = URL(string: pullRequest.url) else { return }
        let project = project(for: pullRequest)
        let title = "\(pullRequest.repository.split(separator: "/").last.map(String.init) ?? pullRequest.repository)#\(pullRequest.number) \(pullRequest.title)"
        let workspace = tabManager.addWorkspace(title: title, workingDirectory: project?.root, select: true)
        tabManager.focusTab(workspace.id)
        workspaces[pullRequest.url] = workspace.id
        let viewer = inbox?.viewer
        Task {
            let profileID = await Self.gitHubProfileID(viewer: viewer)
            guard let terminalId = workspace.focusedPanelId ?? workspace.panels.keys.first,
                  workspace.newBrowserSplit(
                      from: terminalId,
                      orientation: .horizontal,
                      insertFirst: true,
                      url: url,
                      preferredProfileID: profileID,
                      focus: true,
                      initialDividerPosition: 0.64
                  ) != nil
            else {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    /// The browser profile signed in to GitHub, so pull requests open signed in.
    ///
    /// Each cmux browser profile keeps its own cookies, and Import Browser Data
    /// can bring a GitHub login into a profile other than Default. GitHub marks
    /// a signed-in browser with `logged_in=yes` and the login in `dotcom_user`.
    /// Prefers a profile signed in as `viewer` (the `gh` account), then the
    /// last used profile, then Default; `nil` (Default) when none is signed in.
    static func gitHubProfileID(viewer: String?) async -> UUID? {
        let store = BrowserProfileStore.shared
        var candidates = [store.lastUsedProfileID, store.builtInDefaultProfileID]
        candidates += store.profiles.map(\.id).filter { !candidates.contains($0) }
        var signedIn: [(id: UUID, user: String?)] = []
        for id in candidates {
            let cookies = await store.websiteDataStore(for: id).httpCookieStore.allCookies()
                .filter { $0.domain.hasSuffix("github.com") }
            guard cookies.contains(where: { $0.name == "logged_in" && $0.value == "yes" }) else { continue }
            signedIn.append((id, cookies.first { $0.name == "dotcom_user" }?.value))
        }
        if let viewer, let match = signedIn.first(where: { $0.user?.caseInsensitiveCompare(viewer) == .orderedSame }) {
            return match.id
        }
        return signedIn.first?.id
    }

    /// Opens a pull request in the default browser.
    func openInBrowser(_ pullRequest: GitHubPullRequest) {
        if let url = URL(string: pullRequest.url) { NSWorkspace.shared.open(url) }
    }

    /// The prompt for "Review with agent".
    static func reviewPrompt(for pullRequest: GitHubPullRequest) -> String {
        String(
            localized: "agentHome.prs.reviewPrompt",
            defaultValue: "Review \(pullRequest.url). Check out the branch, read the change and run the relevant tests. Then tell me what it does, anything that looks wrong or risky, and whether you'd approve it. Don't post anything on GitHub."
        )
    }
}

// MARK: - gh

struct GitHubCLIError: Error {
    let message: String
}

/// Runs the `gh` CLI. GUI apps don't get the shell's PATH, so it's looked up in the usual places.
enum GitHubCLI {
    static let candidatePaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    static var executable: String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Fetches the inbox, trying once more when GitHub has a hiccup (its search API sometimes returns 502).
    static func fetchInbox() -> Result<GitHubPullRequestInbox, GitHubCLIError> {
        let first = fetchOnce()
        if case .failure = first, executable != nil {
            Thread.sleep(forTimeInterval: 2)
            return fetchOnce()
        }
        return first
    }

    private static func fetchOnce() -> Result<GitHubPullRequestInbox, GitHubCLIError> {
        guard let gh = executable else {
            return .failure(GitHubCLIError(message: String(
                localized: "agentHome.prs.noGh",
                defaultValue: "Install the GitHub CLI (brew install gh) and sign in with gh auth login to see your pull requests."
            )))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = [
            "api", "graphql",
            "-F", "review=\(GitHubPullRequestInbox.reviewSearch)",
            "-F", "mine=\(GitHubPullRequestInbox.mineSearch)",
            "-f", "query=\(GitHubPullRequestInbox.query)",
        ]
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
        if let inbox = GitHubPullRequestInbox.parse(data) { return .success(inbox) }
        let detail = errorText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if detail.contains("auth login") || detail.contains("401") {
            return .failure(GitHubCLIError(message: String(
                localized: "agentHome.prs.signIn",
                defaultValue: "Sign in to GitHub with gh auth login to see your pull requests."
            )))
        }
        return .failure(GitHubCLIError(message: detail.isEmpty
            ? String(localized: "agentHome.prs.failed", defaultValue: "Couldn't reach GitHub. Will try again shortly.")
            : String(localized: "agentHome.prs.failedDetail", defaultValue: "Couldn't reach GitHub: \(detail)")))
    }
}
