import Foundation

/// Which pull request: `owner/name` and number.
public struct GitHubPullRequestRef: Hashable, Sendable, Identifiable {
    public var repository: String
    public var number: Int

    public init(repository: String, number: Int) {
        self.repository = repository
        self.number = number
    }

    public var id: String { Self.key(repository: repository, number: number) }

    /// `owner/name#number` with the repository lowercased: how Agent Home and
    /// T3 key a pull request, whatever case its repository was written in.
    public static func key(repository: String, number: Int) -> String {
        "\(repository.lowercased())#\(number)"
    }
    public var owner: String { String(repository.split(separator: "/").first ?? "") }
    public var name: String { String(repository.split(separator: "/").dropFirst().first ?? "") }
    public var url: URL? { URL(string: "https://github.com/\(repository)/pull/\(number)") }

    /// Reads `https://github.com/owner/name/pull/123[/…]`.
    public init?(url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard url.host?.hasSuffix("github.com") == true, parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]) else { return nil }
        self.init(repository: "\(parts[0])/\(parts[1])", number: number)
    }
}

/// Someone on GitHub.
public struct GitHubActor: Hashable, Sendable {
    public var login: String
    public var avatarURL: URL?

    public init(login: String, avatarURL: URL? = nil) {
        self.login = login
        self.avatarURL = avatarURL
    }

    /// Bots read as `name[bot]` in REST and as `name` with a `Bot` type in GraphQL.
    public var isBot: Bool { login.hasSuffix("[bot]") || login.hasSuffix("-bot") }

    static func parse(_ object: Any?) -> GitHubActor? {
        guard let object = object as? [String: Any], let login = object["login"] as? String else { return nil }
        let isBot = object["__typename"] as? String == "Bot"
        return GitHubActor(
            login: isBot && !login.hasSuffix("[bot]") ? "\(login)[bot]" : login,
            avatarURL: (object["avatarUrl"] as? String).flatMap(URL.init(string:))
        )
    }
}

/// A pull request in full, for the detail view: what T3's detail panel shows.
public struct GitHubPullRequestDetail: Hashable, Sendable {
    public enum State: String, Sendable { case open, closed, merged }

    /// A check on the head commit.
    public struct Check: Hashable, Sendable, Identifiable {
        /// T3's check statuses.
        public enum Status: String, Sendable {
            case pending, actionRequired, success, failure, cancelled, skipped, neutral
        }

        public var name: String
        /// The workflow a check run belongs to, when GitHub says.
        public var workflow: String?
        public var status: Status
        public var description: String?
        public var url: URL?
        public var isRequired: Bool

        public var id: String { "\(workflow ?? "")/\(name)" }

        public init(name: String, workflow: String? = nil, status: Status, description: String? = nil, url: URL? = nil, isRequired: Bool = false) {
            self.name = name
            self.workflow = workflow
            self.status = status
            self.description = description
            self.url = url
            self.isRequired = isRequired
        }

        /// Whether it needs someone: failed, cancelled, or waiting for approval.
        public var needsAttention: Bool { status == .failure || status == .cancelled || status == .actionRequired }
    }

    /// A reviewer: someone asked to review, with their latest verdict if any.
    public struct Reviewer: Hashable, Sendable, Identifiable {
        public enum Verdict: String, Sendable { case approved, changesRequested, commented, dismissed }

        public var actor: GitHubActor
        public var verdict: Verdict?
        /// The verdict is older than the newest commit.
        public var isStale: Bool

        public var id: String { actor.login }

        public init(actor: GitHubActor, verdict: Verdict?, isStale: Bool = false) {
            self.actor = actor
            self.verdict = verdict
            self.isStale = isStale
        }
    }

    public struct Label: Hashable, Sendable, Identifiable {
        public var name: String
        /// Hex without `#`.
        public var color: String
        public var id: String { name }

        public init(name: String, color: String) {
            self.name = name
            self.color = color
        }
    }

    /// A comment, a review, or a review's code comment.
    public struct Comment: Hashable, Sendable, Identifiable {
        public enum Kind: Sendable { case comment, review, reviewComment }

        public var id: String
        public var kind: Kind
        public var author: GitHubActor?
        /// GitHub's rendered HTML for the body.
        public var bodyHTML: String
        public var createdAt: Date?
        public var url: URL?
        /// A review's verdict.
        public var verdict: Reviewer.Verdict?

        public init(id: String, kind: Kind, author: GitHubActor?, bodyHTML: String, createdAt: Date?, url: URL? = nil, verdict: Reviewer.Verdict? = nil) {
            self.id = id
            self.kind = kind
            self.author = author
            self.bodyHTML = bodyHTML
            self.createdAt = createdAt
            self.url = url
            self.verdict = verdict
        }

        /// Whether the body has no visible text.
        public var isEmpty: Bool {
            bodyHTML.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// A conversation on a line of code.
    public struct ReviewThread: Hashable, Sendable, Identifiable {
        public var id: String
        public var path: String
        /// The line in the new file, or nil when the code has moved on (outdated).
        public var line: Int?
        public var isResolved: Bool
        public var isOutdated: Bool
        /// The diff the first comment was made on, ending at the commented line.
        public var diffHunk: String?
        public var comments: [Comment]

        public init(id: String, path: String, line: Int?, isResolved: Bool, isOutdated: Bool, diffHunk: String?, comments: [Comment]) {
            self.id = id
            self.path = path
            self.line = line
            self.isResolved = isResolved
            self.isOutdated = isOutdated
            self.diffHunk = diffHunk
            self.comments = comments
        }
    }

    public struct Commit: Hashable, Sendable, Identifiable {
        public var oid: String
        public var headline: String
        public var date: Date?
        public var author: String?
        public var id: String { oid }
        public var shortOid: String { String(oid.prefix(7)) }

        public init(oid: String, headline: String, date: Date?, author: String?) {
            self.oid = oid
            self.headline = headline
            self.date = date
            self.author = author
        }
    }

    public enum MergeMethod: String, Sendable, CaseIterable {
        case merge, squash, rebase
    }

    public var ref: GitHubPullRequestRef
    public var url: URL?
    public var title: String
    public var bodyHTML: String
    public var state: State
    public var isDraft: Bool
    public var author: GitHubActor?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var mergedAt: Date?
    public var closedAt: Date?
    public var headBranch: String
    public var baseBranch: String
    public var headSha: String?
    public var additions: Int
    public var deletions: Int
    public var changedFiles: Int
    /// `MERGEABLE`, `CONFLICTING` or `UNKNOWN`, lowercased.
    public var mergeability: String
    /// `BEHIND` and the like, lowercased: GitHub's merge state.
    public var mergeState: String?
    public var reviewDecision: String?
    public var labels: [Label]
    public var reviewers: [Reviewer]
    public var checks: [Check]
    public var allowedMergeMethods: [MergeMethod]
    public var autoMergeEnabled: Bool
    public var comments: [Comment]
    public var reviews: [Comment]
    public var reviewThreads: [ReviewThread]
    public var commits: [Commit]
    /// The signed-in user, from the same query.
    public var viewer: String?

    public var isOpen: Bool { state == .open }
    public var isConflicting: Bool { mergeability == "conflicting" }
    public var isBehind: Bool { mergeState == "behind" }

    /// T3's overall checks state: failing if any failed, pending if any are
    /// still going, passing if any passed, else nil (no checks).
    public var checksState: T3Thread.PullRequest.Checks? {
        if checks.contains(where: { $0.status == .failure || $0.status == .cancelled }) { return .failing }
        if checks.contains(where: { $0.status == .pending || $0.status == .actionRequired }) { return .pending }
        if checks.contains(where: { $0.status == .success }) { return .passing }
        return nil
    }

    /// "2 failing, 1 running, 14 passed", in T3's order.
    public var checksSummary: (failing: Int, running: Int, passed: Int, skipped: Int) {
        (
            checks.filter { $0.status == .failure || $0.status == .cancelled || $0.status == .actionRequired }.count,
            checks.filter { $0.status == .pending }.count,
            checks.filter { $0.status == .success }.count,
            checks.filter { $0.status == .skipped || $0.status == .neutral }.count
        )
    }

    /// The header's one primary control, in T3's order.
    public enum PrimaryAction: Hashable, Sendable {
        case state(State)
        case resolveConflicts
        case readyForReview
        case autoMergeEnabled
        case merge(MergeMethod)
        /// Nothing the user can do yet (no allowed merge method).
        case none
    }

    public var primaryAction: PrimaryAction {
        guard isOpen else { return .state(state) }
        if isConflicting { return .resolveConflicts }
        if isDraft { return .readyForReview }
        if autoMergeEnabled { return .autoMergeEnabled }
        guard let method = allowedMergeMethods.first else { return .none }
        return .merge(method)
    }

    // MARK: - Parsing

    /// The GraphQL query ``parse(graphQL:)`` reads. Variables: `owner`, `name`, `number`.
    public static let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          viewer { login }
          repository(owner: $owner, name: $name) {
            mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed
            pullRequest(number: $number) {
              number title url state isDraft bodyHTML
              author { __typename login avatarUrl }
              createdAt updatedAt mergedAt closedAt
              headRefName baseRefName headRefOid additions deletions changedFiles
              mergeable mergeStateStatus reviewDecision
              autoMergeRequest { enabledAt }
              labels(first: 20) { nodes { name color } }
              reviewRequests(first: 20) { nodes { requestedReviewer { __typename ... on User { login avatarUrl } ... on Team { name } ... on Bot { login avatarUrl } } } }
              latestOpinionatedReviews(first: 30) { nodes { author { __typename login avatarUrl } state submittedAt } }
              commits(last: 100) { nodes { commit { oid messageHeadline committedDate author { name user { login } }
                statusCheckRollup { contexts(first: 100) { nodes { __typename
                  ... on CheckRun { name status conclusion detailsUrl isRequired(pullRequestNumber: $number) checkSuite { workflowRun { workflow { name } } } }
                  ... on StatusContext { context state targetUrl description isRequired(pullRequestNumber: $number) } } } } } } }
              comments(last: 100) { nodes { id url bodyHTML createdAt author { __typename login avatarUrl } } }
              reviews(last: 50) { nodes { id url state bodyHTML submittedAt author { __typename login avatarUrl } } }
              reviewThreads(first: 100) { nodes { id path line isResolved isOutdated
                comments(first: 30) { nodes { id url bodyHTML createdAt diffHunk author { __typename login avatarUrl } } } } }
            }
          }
        }
        """

    /// Reads ``query``'s response, or nil when it holds no pull request.
    public static func parse(graphQL data: Data, ref: GitHubPullRequestRef) -> GitHubPullRequestDetail? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObject = root["data"] as? [String: Any],
              let repository = dataObject["repository"] as? [String: Any],
              let pr = repository["pullRequest"] as? [String: Any]
        else { return nil }

        func nodes(_ value: Any?) -> [[String: Any]] {
            ((value as? [String: Any])?["nodes"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        }
        func string(_ object: [String: Any], _ key: String) -> String? { object[key] as? String }
        func int(_ object: [String: Any], _ key: String) -> Int { (object[key] as? NSNumber)?.intValue ?? 0 }
        func date(_ object: [String: Any], _ key: String) -> Date? { T3Dates.parse(object[key] as? String) }

        let stateText = (string(pr, "state") ?? "OPEN").lowercased()
        let commits: [Commit] = nodes(pr["commits"]).compactMap { node in
            guard let commit = node["commit"] as? [String: Any], let oid = string(commit, "oid") else { return nil }
            let author = commit["author"] as? [String: Any]
            let login = (author?["user"] as? [String: Any])?["login"] as? String
            return Commit(oid: oid, headline: string(commit, "messageHeadline") ?? "", date: date(commit, "committedDate"), author: login ?? author?["name"] as? String)
        }
        let headCommit = nodes(pr["commits"]).last?["commit"] as? [String: Any]
        let rollup = headCommit?["statusCheckRollup"] as? [String: Any]
        let checks = nodes(rollup?["contexts"]).compactMap(parseCheck)

        let latestCommitDate = commits.compactMap(\.date).max()
        var reviewers: [Reviewer] = []
        for node in nodes(pr["latestOpinionatedReviews"]) {
            guard let actor = GitHubActor.parse(node["author"]) else { continue }
            let submitted = date(node, "submittedAt")
            reviewers.append(Reviewer(
                actor: actor,
                verdict: parseVerdict(string(node, "state")),
                isStale: submitted.flatMap { submitted in latestCommitDate.map { submitted < $0 } } ?? false
            ))
        }
        for node in nodes(pr["reviewRequests"]) {
            guard let requested = node["requestedReviewer"] as? [String: Any] else { continue }
            let login = string(requested, "login") ?? string(requested, "name").map { "@\($0)" }
            guard let login, !reviewers.contains(where: { $0.actor.login == login }) else { continue }
            reviewers.append(Reviewer(actor: GitHubActor(login: login, avatarURL: string(requested, "avatarUrl").flatMap(URL.init(string:))), verdict: nil))
        }

        let comments = nodes(pr["comments"]).map { node in
            Comment(id: string(node, "id") ?? UUID().uuidString, kind: .comment, author: GitHubActor.parse(node["author"]),
                    bodyHTML: string(node, "bodyHTML") ?? "", createdAt: date(node, "createdAt"),
                    url: string(node, "url").flatMap(URL.init(string:)))
        }
        let reviews = nodes(pr["reviews"]).map { node in
            Comment(id: string(node, "id") ?? UUID().uuidString, kind: .review, author: GitHubActor.parse(node["author"]),
                    bodyHTML: string(node, "bodyHTML") ?? "", createdAt: date(node, "submittedAt"),
                    url: string(node, "url").flatMap(URL.init(string:)), verdict: parseVerdict(string(node, "state")))
        }
        let threads = nodes(pr["reviewThreads"]).map { node in
            let threadComments = nodes(node["comments"])
            return ReviewThread(
                id: string(node, "id") ?? UUID().uuidString,
                path: string(node, "path") ?? "",
                line: (node["line"] as? NSNumber)?.intValue,
                isResolved: node["isResolved"] as? Bool ?? false,
                isOutdated: node["isOutdated"] as? Bool ?? false,
                diffHunk: threadComments.first.flatMap { string($0, "diffHunk") },
                comments: threadComments.map { comment in
                    Comment(id: string(comment, "id") ?? UUID().uuidString, kind: .reviewComment, author: GitHubActor.parse(comment["author"]),
                            bodyHTML: string(comment, "bodyHTML") ?? "", createdAt: date(comment, "createdAt"),
                            url: string(comment, "url").flatMap(URL.init(string:)))
                }
            )
        }

        var methods: [MergeMethod] = []
        if repository["mergeCommitAllowed"] as? Bool == true { methods.append(.merge) }
        if repository["squashMergeAllowed"] as? Bool == true { methods.append(.squash) }
        if repository["rebaseMergeAllowed"] as? Bool == true { methods.append(.rebase) }

        return GitHubPullRequestDetail(
            ref: ref,
            url: string(pr, "url").flatMap(URL.init(string:)) ?? ref.url,
            title: string(pr, "title") ?? "",
            bodyHTML: string(pr, "bodyHTML") ?? "",
            state: State(rawValue: stateText) ?? .open,
            isDraft: pr["isDraft"] as? Bool ?? false,
            author: GitHubActor.parse(pr["author"]),
            createdAt: date(pr, "createdAt"),
            updatedAt: date(pr, "updatedAt"),
            mergedAt: date(pr, "mergedAt"),
            closedAt: date(pr, "closedAt"),
            headBranch: string(pr, "headRefName") ?? "",
            baseBranch: string(pr, "baseRefName") ?? "",
            headSha: string(pr, "headRefOid"),
            additions: int(pr, "additions"),
            deletions: int(pr, "deletions"),
            changedFiles: int(pr, "changedFiles"),
            mergeability: (string(pr, "mergeable") ?? "UNKNOWN").lowercased(),
            mergeState: string(pr, "mergeStateStatus")?.lowercased(),
            reviewDecision: string(pr, "reviewDecision")?.lowercased().replacingOccurrences(of: "_", with: "-"),
            labels: nodes(pr["labels"]).compactMap { node in
                string(node, "name").map { Label(name: $0, color: string(node, "color") ?? "888888") }
            },
            reviewers: reviewers,
            checks: checks,
            allowedMergeMethods: methods,
            autoMergeEnabled: pr["autoMergeRequest"] is [String: Any],
            comments: comments,
            reviews: reviews,
            reviewThreads: threads,
            commits: commits,
            viewer: (dataObject["viewer"] as? [String: Any])?["login"] as? String
        )
    }

    static func parseVerdict(_ state: String?) -> Reviewer.Verdict? {
        switch state?.uppercased() {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "COMMENTED": return .commented
        case "DISMISSED": return .dismissed
        default: return nil
        }
    }

    /// A check run or commit status, in T3's statuses.
    static func parseCheck(_ node: [String: Any]) -> Check? {
        if node["__typename"] as? String == "StatusContext" {
            guard let name = node["context"] as? String else { return nil }
            let status: Check.Status = switch (node["state"] as? String)?.uppercased() {
            case "SUCCESS": .success
            case "FAILURE", "ERROR": .failure
            default: .pending
            }
            return Check(name: name, status: status, description: node["description"] as? String,
                         url: (node["targetUrl"] as? String).flatMap(URL.init(string:)), isRequired: node["isRequired"] as? Bool ?? false)
        }
        guard let name = node["name"] as? String else { return nil }
        let workflow = ((((node["checkSuite"] as? [String: Any])?["workflowRun"] as? [String: Any])?["workflow"] as? [String: Any])?["name"] as? String)
        let status: Check.Status
        if (node["status"] as? String)?.uppercased() != "COMPLETED" {
            status = (node["status"] as? String)?.uppercased() == "WAITING" ? .actionRequired : .pending
        } else {
            status = switch (node["conclusion"] as? String)?.uppercased() {
            case "SUCCESS": .success
            case "FAILURE", "TIMED_OUT", "STARTUP_FAILURE": .failure
            case "CANCELLED": .cancelled
            case "SKIPPED": .skipped
            case "NEUTRAL", "STALE": .neutral
            case "ACTION_REQUIRED": .actionRequired
            default: .neutral
            }
        }
        return Check(name: name, workflow: workflow, status: status,
                     url: (node["detailsUrl"] as? String).flatMap(URL.init(string:)), isRequired: node["isRequired"] as? Bool ?? false)
    }
}

/// T3's timeline: what happened on a pull request, newest first.
public enum GitHubPullRequestTimeline {
    public enum Entry: Hashable, Sendable, Identifiable {
        case opened(GitHubActor?, Date?)
        case commit(GitHubPullRequestDetail.Commit)
        /// Consecutive plain comments fold into one entry.
        case comments([GitHubPullRequestDetail.Comment])
        /// A review with a verdict or a body.
        case review(GitHubPullRequestDetail.Comment, isStale: Bool)
        case merged(Date?)
        case closed(Date?)

        public var id: String {
            switch self {
            case .opened: "opened"
            case .commit(let commit): "commit-\(commit.oid)"
            case .comments(let comments): "comments-\(comments.first?.id ?? "")"
            case .review(let review, _): "review-\(review.id)"
            case .merged: "merged"
            case .closed: "closed"
            }
        }

        public var date: Date? {
            switch self {
            case .opened(_, let date), .merged(let date), .closed(let date): date
            case .commit(let commit): commit.date
            case .comments(let comments): comments.first?.createdAt
            case .review(let review, _): review.createdAt
            }
        }
    }

    /// Builds the timeline.
    ///
    /// - Parameters:
    ///   - detail: The pull request.
    ///   - newestFirst: T3's default; false reads oldest first.
    /// - Returns: The entries.
    public static func entries(for detail: GitHubPullRequestDetail, newestFirst: Bool = true) -> [Entry] {
        var events: [Entry] = [.opened(detail.author, detail.createdAt)]
        events += detail.commits.map(Entry.commit)
        let latestCommit = detail.commits.compactMap(\.date).max()
        for review in detail.reviews where review.verdict != .commented || !review.isEmpty {
            let stale = review.verdict == .approved && (review.createdAt.flatMap { date in latestCommit.map { date < $0 } } ?? false)
            events.append(.review(review, isStale: stale))
        }
        events += detail.comments.map { .comments([$0]) }
        if detail.state == .merged { events.append(.merged(detail.mergedAt)) }
        if detail.state == .closed { events.append(.closed(detail.closedAt)) }

        let sorted = events.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        // Fold runs of plain comments.
        var folded: [Entry] = []
        for event in sorted {
            if case .comments(let next) = event, case .comments(let run)? = folded.last {
                folded[folded.count - 1] = .comments(run + next)
            } else {
                folded.append(event)
            }
        }
        return newestFirst ? folded.reversed() : folded
    }
}
