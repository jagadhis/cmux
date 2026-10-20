import Foundation

/// A pull request the user is involved in on GitHub: one they're asked to review, or one they opened.
public struct GitHubPullRequest: Identifiable, Hashable, Sendable {
    /// CI state of the head commit.
    public enum Checks: String, Sendable {
        case passing, failing, running, none
    }

    /// Where review stands.
    public enum Review: String, Sendable {
        case approved, changesRequested, required, none
    }

    /// The pull request URL, which identifies it.
    public var id: String { url }
    public var url: String
    /// `owner/name`.
    public var repository: String
    public var number: Int
    public var title: String
    public var author: String?
    public var isDraft: Bool
    public var createdAt: Date?
    public var updatedAt: Date?
    public var headBranch: String?
    public var additions: Int
    public var deletions: Int
    public var comments: Int
    public var checks: Checks
    public var review: Review
    /// Whether it can't merge because of conflicts.
    public var hasConflicts: Bool
    /// The user's own latest review, such as `APPROVED` or `COMMENTED`, if they reviewed it.
    public var viewerReviewState: String?

    public init(
        url: String,
        repository: String,
        number: Int,
        title: String,
        author: String? = nil,
        isDraft: Bool = false,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        headBranch: String? = nil,
        additions: Int = 0,
        deletions: Int = 0,
        comments: Int = 0,
        checks: Checks = .none,
        review: Review = .none,
        hasConflicts: Bool = false,
        viewerReviewState: String? = nil
    ) {
        self.url = url
        self.repository = repository
        self.number = number
        self.title = title
        self.author = author
        self.isDraft = isDraft
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.headBranch = headBranch
        self.additions = additions
        self.deletions = deletions
        self.comments = comments
        self.checks = checks
        self.review = review
        self.hasConflicts = hasConflicts
        self.viewerReviewState = viewerReviewState
    }

    /// `owner/name#number`, the key T3 links threads to pull requests by.
    public var key: String { "\(repository)#\(number)" }

    /// What the author should do next with one of their own pull requests, most pressing first.
    public var nextStep: GitHubPullRequestNextStep {
        if isDraft { return .draft }
        if hasConflicts { return .fixConflicts }
        if checks == .failing { return .fixChecks }
        if review == .changesRequested { return .addressReview }
        if review == .approved && checks != .running { return .merge }
        if checks == .running { return .checksRunning }
        return .awaitingReview
    }
}

/// The next step on a pull request the user opened.
public enum GitHubPullRequestNextStep: Int, Sendable, Comparable {
    case fixConflicts, fixChecks, addressReview, merge, checksRunning, awaitingReview, draft

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Steps that are the user's to take now.
    public var isActionable: Bool { self <= .merge }
}

/// The user's pull requests on GitHub, split into the two lists Agent Home shows.
public struct GitHubPullRequestInbox: Hashable, Sendable {
    /// The GitHub login the lists are for.
    public var viewer: String
    /// Open pull requests waiting on the user's review, most recently updated first.
    public var toReview: [GitHubPullRequest]
    /// Open pull requests the user opened, most pressing first.
    public var mine: [GitHubPullRequest]
    /// How many each search matched, which can exceed what was fetched.
    public var toReviewTotal: Int
    public var mineTotal: Int

    public init(viewer: String, toReview: [GitHubPullRequest], mine: [GitHubPullRequest], toReviewTotal: Int, mineTotal: Int) {
        self.viewer = viewer
        self.toReview = toReview
        self.mine = mine
        self.toReviewTotal = toReviewTotal
        self.mineTotal = mineTotal
    }

    /// How many pull requests to fetch for each list.
    public static let pageSize = 25

    /// The GraphQL query: who the user is, PRs requesting their review, and PRs they opened.
    /// Run it with `gh api graphql -F review=<reviewSearch> -F mine=<mineSearch> -f query=<query>`.
    public static let query = """
        query($review: String!, $mine: String!) {
          viewer { login }
          review: search(query: $review, type: ISSUE, first: \(pageSize)) { issueCount nodes { ...pr } }
          mine: search(query: $mine, type: ISSUE, first: \(pageSize)) { issueCount nodes { ...pr } }
        }
        fragment pr on PullRequest {
          number title url isDraft createdAt updatedAt headRefName
          repository { nameWithOwner }
          author { login }
          reviewDecision mergeable additions deletions
          comments { totalCount }
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          latestReviews(first: 20) { nodes { author { login } state } }
        }
        """

    /// Open PRs that request the user's review, directly or through a team.
    public static let reviewSearch = "is:open is:pr review-requested:@me archived:false sort:updated-desc"
    /// Open PRs the user opened.
    public static let mineSearch = "is:open is:pr author:@me archived:false sort:updated-desc"

    /// Parses the query's JSON response.
    ///
    /// - Parameter data: The response body.
    /// - Returns: The inbox, or `nil` when the response has no data (an error response).
    public static func parse(_ data: Data) -> GitHubPullRequestInbox? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["data"] as? [String: Any]
        else { return nil }
        let viewer = ((body["viewer"] as? [String: Any])?["login"] as? String) ?? ""
        func list(_ key: String) -> (items: [GitHubPullRequest], total: Int) {
            let search = body[key] as? [String: Any]
            let nodes = search?["nodes"] as? [[String: Any]] ?? []
            return (nodes.compactMap { pullRequest($0, viewer: viewer) }, search?["issueCount"] as? Int ?? 0)
        }
        let review = list("review")
        let mine = list("mine")
        return GitHubPullRequestInbox(
            viewer: viewer,
            toReview: review.items,
            mine: mine.items.sorted { lhs, rhs in
                lhs.nextStep != rhs.nextStep
                    ? lhs.nextStep < rhs.nextStep
                    : (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
            },
            toReviewTotal: review.total,
            mineTotal: mine.total
        )
    }

    static func pullRequest(_ node: [String: Any], viewer: String) -> GitHubPullRequest? {
        guard let url = node["url"] as? String,
              let number = node["number"] as? Int,
              let repository = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String
        else { return nil }
        let rollup = (((node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["commit"] as? [String: Any])?["statusCheckRollup"] as? [String: Any]
        let reviews = ((node["latestReviews"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let viewerReview = reviews.last { (($0["author"] as? [String: Any])?["login"] as? String) == viewer }
        return GitHubPullRequest(
            url: url,
            repository: repository,
            number: number,
            title: node["title"] as? String ?? "",
            author: (node["author"] as? [String: Any])?["login"] as? String,
            isDraft: node["isDraft"] as? Bool ?? false,
            createdAt: T3CodeStateReader.date(node["createdAt"] as? String),
            updatedAt: T3CodeStateReader.date(node["updatedAt"] as? String),
            headBranch: node["headRefName"] as? String,
            additions: node["additions"] as? Int ?? 0,
            deletions: node["deletions"] as? Int ?? 0,
            comments: (node["comments"] as? [String: Any])?["totalCount"] as? Int ?? 0,
            checks: checks(rollup?["state"] as? String),
            review: review(node["reviewDecision"] as? String),
            hasConflicts: (node["mergeable"] as? String) == "CONFLICTING",
            viewerReviewState: viewerReview?["state"] as? String
        )
    }

    static func checks(_ state: String?) -> GitHubPullRequest.Checks {
        switch state {
        case "SUCCESS": return .passing
        case "FAILURE", "ERROR": return .failing
        case "PENDING", "EXPECTED": return .running
        default: return .none
        }
    }

    static func review(_ decision: String?) -> GitHubPullRequest.Review {
        switch decision {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "REVIEW_REQUIRED": return .required
        default: return .none
        }
    }
}
