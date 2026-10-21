import AppKit
import Bonsplit
import CmuxAgentHome
import Foundation
import Observation
import WebKit

/// The user's GitHub pull requests in Agent Home: the ones waiting on their
/// review and the ones they opened.
///
/// Reads GitHub through the `gh` CLI with the account it's signed in to, every
/// couple of minutes while Agent Home is on screen and cmux is active. Opening
/// a pull request gives it a workspace: the page in a browser beside a
/// terminal in the matching T3 project's folder.
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
    private let gitHub = GitHubCLI()

    /// Reads GitHub every couple of minutes while Agent Home is on screen.
    @ObservationIgnored let poller = AgentHomePoller(interval: .seconds(120))

    private init() {
        poller.action = { [weak self] in await self?.refresh() }
    }

    // MARK: - Loading

    /// Reads GitHub and T3 now.
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        // The T3 model reads the same project list every few seconds; reuse it once it has.
        let knownProjects = AgentHomeT3Model.shared.allProjects
        let local = await Task.detached(priority: .utility) { () -> (projects: [T3CodeStateReader.Project]?, origins: [String: String], threads: [String: T3CodeStateReader.PullRequestThread]?) in
            let read = try? T3CodeStateReader().withConnection { connection in
                (knownProjects.isEmpty ? try? connection.projects() : knownProjects, try? connection.pullRequestThreads())
            }
            let projects = read?.0
            var origins: [String: String] = [:]
            for project in projects ?? [] {
                let config = URL(fileURLWithPath: project.root).appendingPathComponent(".git/config")
                if let text = try? String(contentsOf: config, encoding: .utf8),
                   let repository = GitHubRepositoryMatcher.originRepository(gitConfig: text) {
                    origins[project.id] = repository
                }
            }
            return (projects, origins, read?.1)
        }.value
        // A failed read keeps what was shown; T3 being briefly busy shouldn't empty the lists.
        if let projects = local.projects {
            self.projects = projects
            origins = local.origins
        }
        if let threads = local.threads { linkedThreads = threads }
        #if DEBUG
        if local.projects == nil || local.threads == nil { cmuxDebugLog("agentHome.prs.t3ReadFailed") }
        #endif

        let result = await gitHub.fetchInbox()
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
        guard let url = URL(string: pullRequest.url) else { return }
        openWorkspace(
            pullRequestURL: url,
            repository: pullRequest.repository,
            number: pullRequest.number,
            title: pullRequest.title,
            tabManager: tabManager
        )
    }

    /// Opens a pull request's workspace (creating it the first time) and shows
    /// `load` in its browser, or the pull request page itself.
    func openWorkspace(
        pullRequestURL url: URL,
        repository: String,
        number: Int,
        title pullRequestTitle: String,
        load: URL? = nil,
        tabManager: TabManager
    ) {
        AgentHomeTaskViewState.shared.page = nil
        let page = load ?? url
        if let existing = workspaces[url.absoluteString], tabManager.tabs.contains(where: { $0.id == existing }) {
            tabManager.focusTab(existing)
            if let load,
               let workspace = tabManager.tabs.first(where: { $0.id == existing }),
               let browser = workspace.panels.values.compactMap({ $0 as? BrowserPanel }).first {
                _ = browser.navigate(to: load)
            }
            return
        }
        let project = GitHubRepositoryMatcher.project(for: repository, in: projects, origins: origins)
        let title = "\(repository.split(separator: "/").last.map(String.init) ?? repository)#\(number) \(pullRequestTitle)"
        let workspace = tabManager.addWorkspace(title: title, workingDirectory: project?.root, select: true)
        tabManager.focusTab(workspace.id)
        workspaces[url.absoluteString] = workspace.id
        openGitHubSplit(
            page,
            in: workspace,
            beside: workspace.focusedPanelId ?? workspace.panels.keys.first,
            orientation: .horizontal,
            insertFirst: true,
            dividerPosition: 0.64
        )
    }

    /// Opens a GitHub page in a browser split in `workspace`, signed in to
    /// GitHub when a browser profile is, or in the default browser when the
    /// split can't open. Pull requests and their links open through here,
    /// from the Pull requests page and from a T3 task's linked pull requests.
    func openGitHubSplit(
        _ url: URL,
        in workspace: Workspace,
        beside anchor: UUID?,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        dividerPosition: CGFloat? = nil
    ) {
        let viewer = inbox?.viewer
        Task {
            let profileID = await Self.gitHubProfileID(viewer: viewer)
            guard let anchor,
                  workspace.newBrowserSplit(
                      from: anchor,
                      orientation: orientation,
                      insertFirst: insertFirst,
                      url: url,
                      preferredProfileID: profileID,
                      focus: true,
                      initialDividerPosition: dividerPosition
                  ) != nil
            else {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    /// The T3 project whose folder holds a repository.
    func project(forRepository repository: String) -> T3CodeStateReader.Project? {
        GitHubRepositoryMatcher.project(for: repository, in: projects, origins: origins)
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
        reviewPrompt(url: pullRequest.url)
    }

    static func reviewPrompt(url: String) -> String {
        String(
            localized: "agentHome.prs.reviewPrompt",
            defaultValue: "Review \(url). Check out the branch, read the change and run the relevant tests. Then tell me what it does, anything that looks wrong or risky, and whether you'd approve it. Don't post anything on GitHub."
        )
    }
}
