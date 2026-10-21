import AppKit
import CmuxAgentHome
import CryptoKit
import Foundation
import Observation

/// A pull request's detail in Agent Home, as T3's detail panel shows it:
/// read through the `gh` CLI, with T3's actions (ready, merge, close,
/// comment, review) run the same way.
@MainActor
@Observable
final class AgentHomePullRequestDetailModel {
    static let shared = AgentHomePullRequestDetailModel()

    /// What's loaded for one pull request.
    struct Entry {
        var detail: GitHubPullRequestDetail?
        var files: [GitHubPullRequestFile]?
        /// Each file's diff hash, by path, worked out once per load for the viewed marks.
        var diffHashes: [String: String] = [:]
        var error: String?
        var filesError: String?
        var isLoading = false
        var loadedAt: Date?
    }

    private(set) var entries: [String: Entry] = [:]
    /// Pull request ids, least recently loaded first, so only the last few stay in memory.
    private var entryOrder: [String] = []
    private static let maximumEntries = 10
    /// Actions in flight, by pull request id.
    private(set) var pending: [String: String] = [:]
    /// The last action's outcome, by pull request id.
    private(set) var outcomes: [String: AgentHomeT3PullRequestActions.Outcome] = [:]
    /// Files the user marked viewed: pull request id → path → a hash of the
    /// diff they saw, so a file that changes afterwards reads as changed.
    private var viewed: [String: [String: String]]

    private static let viewedDefaultsKey = "agentHomePullRequestViewedFiles"
    private let gitHub = GitHubCLI()

    private init() {
        viewed = UserDefaults.standard.dictionary(forKey: Self.viewedDefaultsKey) as? [String: [String: String]] ?? [:]
    }

    func entry(for ref: GitHubPullRequestRef) -> Entry { entries[ref.id] ?? Entry() }

    // MARK: - Loading

    /// Loads the detail and the files, unless they were read in the last
    /// minute. Pass `force` for Refresh.
    func load(_ ref: GitHubPullRequestRef, force: Bool = false) {
        var entry = entries[ref.id] ?? Entry()
        guard !entry.isLoading else { return }
        touch(ref.id)
        if !force, let loadedAt = entry.loadedAt, Date().timeIntervalSince(loadedAt) < 60, entry.detail != nil { return }
        entry.isLoading = true
        entries[ref.id] = entry
        let gitHub = gitHub
        Task {
            async let detail = Self.fetchDetail(ref, gitHub: gitHub)
            async let files = Self.fetchFiles(ref, gitHub: gitHub)
            let (detailResult, filesResult) = await (detail, files)
            var entry = entries[ref.id] ?? Entry()
            entry.isLoading = false
            entry.loadedAt = Date()
            switch detailResult {
            case .success(let detail):
                entry.detail = detail
                entry.error = nil
                // Viewed marks only help while a pull request can still change.
                if detail.state != .open, viewed[ref.id] != nil {
                    viewed[ref.id] = nil
                    UserDefaults.standard.set(viewed, forKey: Self.viewedDefaultsKey)
                }
            case .failure(let error): entry.error = error.message
            }
            switch filesResult {
            case .success(let files):
                entry.files = files.files
                entry.diffHashes = files.hashes
                entry.filesError = nil
            case .failure(let error): entry.filesError = error.message
            }
            entries[ref.id] = entry
        }
    }

    /// Marks a pull request as just used and forgets the least recently used
    /// ones past ``maximumEntries``, except any still loading.
    private func touch(_ id: String) {
        entryOrder.removeAll { $0 == id }
        entryOrder.append(id)
        while entryOrder.count > Self.maximumEntries,
              let oldest = entryOrder.first(where: { entries[$0]?.isLoading != true }) {
            entryOrder.removeAll { $0 == oldest }
            entries[oldest] = nil
        }
    }

    nonisolated static func fetchDetail(_ ref: GitHubPullRequestRef, gitHub: GitHubCLI) async -> Result<GitHubPullRequestDetail, GitHubCLIError> {
        let result = await gitHub.run([
            "api", "graphql",
            "-F", "owner=\(ref.owner)", "-F", "name=\(ref.name)", "-F", "number=\(ref.number)",
            "-f", "query=\(GitHubPullRequestDetail.query)",
        ])
        switch result {
        case .success(let text):
            guard let detail = GitHubPullRequestDetail.parse(graphQL: Data(text.utf8), ref: ref) else {
                return .failure(GitHubCLIError(message: String(localized: "agentHome.pr.notFound", defaultValue: "GitHub didn't return this pull request.")))
            }
            return .success(detail)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// The changed files in review order, with each one's diff hash.
    struct LoadedFiles: Sendable {
        var files: [GitHubPullRequestFile]
        var hashes: [String: String]
    }

    nonisolated static func fetchFiles(_ ref: GitHubPullRequestRef, gitHub: GitHubCLI) async -> Result<LoadedFiles, GitHubCLIError> {
        let result = await gitHub.run(["api", "repos/\(ref.repository)/pulls/\(ref.number)/files?per_page=100", "--paginate", "--slurp"])
        switch result {
        case .success(let text):
            guard let pages = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[Any]] else {
                return .failure(GitHubCLIError(message: String(localized: "agentHome.pr.filesFailed", defaultValue: "Couldn't read the changed files.")))
            }
            let files = GitHubPullRequestFile.reviewOrder(
                pages.flatMap { $0 }.compactMap { ($0 as? [String: Any]).flatMap(GitHubPullRequestFile.fromREST) }
            )
            return .success(LoadedFiles(
                files: files,
                hashes: Dictionary(files.map { ($0.path, hash($0)) }, uniquingKeysWith: { first, _ in first })
            ))
        case .failure(let error):
            return .failure(error)
        }
    }

    // MARK: - Viewed files

    enum ViewedState { case unviewed, viewed, changedSinceViewed }

    func viewedState(of file: GitHubPullRequestFile, in ref: GitHubPullRequestRef) -> ViewedState {
        guard let seen = viewed[ref.id]?[file.path] else { return .unviewed }
        return seen == diffHash(of: file, in: ref) ? .viewed : .changedSinceViewed
    }

    func setViewed(_ isViewed: Bool, file: GitHubPullRequestFile, in ref: GitHubPullRequestRef) {
        var files = viewed[ref.id] ?? [:]
        files[file.path] = isViewed ? diffHash(of: file, in: ref) : nil
        viewed[ref.id] = files.isEmpty ? nil : files
        UserDefaults.standard.set(viewed, forKey: Self.viewedDefaultsKey)
    }

    func viewedCount(_ files: [GitHubPullRequestFile], in ref: GitHubPullRequestRef) -> Int {
        files.filter { viewedState(of: $0, in: ref) == .viewed }.count
    }

    /// The file's diff hash from its load, hashing it only if it isn't there.
    private func diffHash(of file: GitHubPullRequestFile, in ref: GitHubPullRequestRef) -> String {
        entries[ref.id]?.diffHashes[file.path] ?? Self.hash(file)
    }

    nonisolated private static func hash(_ file: GitHubPullRequestFile) -> String {
        let digest = SHA256.hash(data: Data((file.patch ?? "\(file.additions)/\(file.deletions)").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Actions

    enum Action: Equatable {
        case ready, draft, close, reopen
        case merge(GitHubPullRequestDetail.MergeMethod)
        case comment(String)
        case review(verdict: Verdict, body: String)

        enum Verdict: String { case comment, approve, requestChanges = "request-changes" }
    }

    /// Runs an action on GitHub, then reloads the pull request.
    func run(_ action: Action, on ref: GitHubPullRequestRef) {
        guard pending[ref.id] == nil else { return }
        pending[ref.id] = Self.pendingLabel(action)
        outcomes[ref.id] = nil
        let arguments = Self.arguments(for: action, ref: ref)
        Task {
            let result = await gitHub.run(arguments, changesGitHub: true)
            pending[ref.id] = nil
            switch result {
            case .success:
                show(ref, .init(message: Self.doneMessage(action), failed: false))
                load(ref, force: true)
            case .failure(let error):
                show(ref, .init(message: error.message, failed: true))
            }
        }
    }

    private func show(_ ref: GitHubPullRequestRef, _ outcome: AgentHomeT3PullRequestActions.Outcome) {
        outcomes[ref.id] = outcome
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if self?.outcomes[ref.id] == outcome { self?.outcomes[ref.id] = nil }
        }
    }

    static func arguments(for action: Action, ref: GitHubPullRequestRef) -> [String] {
        let target = [String(ref.number), "--repo", ref.repository]
        switch action {
        case .ready: return ["pr", "ready"] + target
        case .draft: return ["pr", "ready"] + target + ["--undo"]
        case .close: return ["pr", "close"] + target
        case .reopen: return ["pr", "reopen"] + target
        case .merge(let method): return ["pr", "merge"] + target + ["--\(method.rawValue)"]
        case .comment(let body): return ["pr", "comment"] + target + ["--body", body]
        case .review(let verdict, let body):
            var arguments = ["pr", "review"] + target + ["--\(verdict.rawValue)"]
            if !body.isEmpty || verdict != .approve { arguments += ["--body", body] }
            return arguments
        }
    }

    private static func pendingLabel(_ action: Action) -> String {
        switch action {
        case .ready: String(localized: "agentHome.pr.pending.ready", defaultValue: "Marking ready…")
        case .draft: String(localized: "agentHome.pr.pending.draft", defaultValue: "Converting to draft…")
        case .close: String(localized: "agentHome.pr.pending.close", defaultValue: "Closing…")
        case .reopen: String(localized: "agentHome.pr.pending.reopen", defaultValue: "Reopening…")
        case .merge: String(localized: "agentHome.pr.pending.merge", defaultValue: "Merging…")
        case .comment: String(localized: "agentHome.pr.pending.comment", defaultValue: "Commenting…")
        case .review: String(localized: "agentHome.pr.pending.review", defaultValue: "Submitting review…")
        }
    }

    private static func doneMessage(_ action: Action) -> String {
        switch action {
        case .ready: String(localized: "agentHome.pr.done.ready", defaultValue: "Marked ready for review.")
        case .draft: String(localized: "agentHome.pr.done.draft", defaultValue: "Converted to draft.")
        case .close: String(localized: "agentHome.pr.done.close", defaultValue: "Closed.")
        case .reopen: String(localized: "agentHome.pr.done.reopen", defaultValue: "Reopened.")
        case .merge: String(localized: "agentHome.pr.done.merge", defaultValue: "Merged.")
        case .comment: String(localized: "agentHome.pr.done.comment", defaultValue: "Comment posted.")
        case .review: String(localized: "agentHome.pr.done.review", defaultValue: "Review submitted.")
        }
    }

    // MARK: - Links

    /// Opens a link from the detail view inside cmux: another pull request in
    /// this view, anything else in the pull request's workspace browser.
    func openLink(_ url: URL, from ref: GitHubPullRequestRef, title: String, tabManager: TabManager) {
        if let other = GitHubPullRequestRef(url: url), url.pathComponents.count <= 5 {
            AgentHomeTaskViewState.shared.showPullRequest(other)
            return
        }
        guard let prURL = ref.url else { return }
        AgentHomePullRequestsModel.shared.openWorkspace(
            pullRequestURL: prURL,
            repository: ref.repository,
            number: ref.number,
            title: title,
            load: url,
            tabManager: tabManager
        )
    }
}
