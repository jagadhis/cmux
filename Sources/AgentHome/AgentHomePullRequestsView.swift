import CmuxAgentHome
import SwiftUI

/// The user's pull requests across GitHub: those waiting on their review and
/// those they opened, each with where it stands and what to do next.
struct AgentHomePullRequestsView: View {
    @ObservedObject var tabManager: TabManager
    let onReviewWithAgent: (GitHubPullRequest) -> Void
    let onOpenThread: (T3CodeStateReader.PullRequestThread) -> Void

    enum Tab: Hashable { case toReview, mine }

    @AppStorage("agentHomePullRequestsTab") private var tabRaw = "toReview"
    private let model = AgentHomePullRequestsModel.shared

    private var tab: Tab { tabRaw == "mine" ? .mine : .toReview }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                    if let error = model.errorMessage, model.inbox == nil {
                        AgentHomePullRequestsEmpty(icon: "exclamationmark.triangle", text: error)
                    } else if let inbox = model.inbox {
                        switch tab {
                        case .toReview: reviewList(inbox)
                        case .mine: mineList(inbox)
                        }
                    } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 60)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        }
        .background(.background)
        .onAppear { model.startIfNeeded() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text(String(localized: "agentHome.prs.title", defaultValue: "Pull requests"))
                .font(.system(size: 13, weight: .semibold))
            Picker("", selection: $tabRaw) {
                Text(String(localized: "agentHome.prs.toReview", defaultValue: "To review · \(model.inbox?.toReviewTotal ?? 0)")).tag("toReview")
                Text(String(localized: "agentHome.prs.mine", defaultValue: "Yours · \(model.inbox?.mineTotal ?? 0)")).tag("mine")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 8)
            if let error = model.errorMessage, model.inbox != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(AgentHomePalette.needsYou)
                    .help(error)
            }
            if let updated = model.lastUpdated {
                Text(String(localized: "agentHome.prs.updated", defaultValue: "Updated \(AgentHomeFormat.relative(updated))"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(model.isLoading ? 360 : 0))
                    .animation(model.isLoading ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: model.isLoading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(String(localized: "agentHome.prs.refresh", defaultValue: "Refresh"))
            .keyboardShortcut("r", modifiers: .command)
            if let viewer = model.inbox?.viewer, !viewer.isEmpty,
               let url = URL(string: tab == .toReview ? "https://github.com/pulls/review-requested" : "https://github.com/pulls") {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .help(String(localized: "agentHome.prs.openGitHub", defaultValue: "Open on GitHub"))
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
    }

    // MARK: - Lists

    @ViewBuilder
    private func reviewList(_ inbox: GitHubPullRequestInbox) -> some View {
        let fresh = inbox.toReview.filter { $0.viewerReviewState == nil }
        let again = inbox.toReview.filter { $0.viewerReviewState != nil }
        if inbox.toReview.isEmpty {
            AgentHomePullRequestsEmpty(icon: "checkmark.circle", text: String(
                localized: "agentHome.prs.noReviews", defaultValue: "Nothing is waiting on your review."
            ))
        }
        section(String(localized: "agentHome.prs.newReviews", defaultValue: "Waiting on your review"), fresh, kind: .review)
        section(String(localized: "agentHome.prs.reReviews", defaultValue: "Asked again after your review"), again, kind: .review)
        moreOnGitHub(shown: inbox.toReview.count, total: inbox.toReviewTotal)
    }

    @ViewBuilder
    private func mineList(_ inbox: GitHubPullRequestInbox) -> some View {
        let actionable = inbox.mine.filter { $0.nextStep.isActionable }
        let waiting = inbox.mine.filter { !$0.nextStep.isActionable }
        if inbox.mine.isEmpty {
            AgentHomePullRequestsEmpty(icon: "arrow.triangle.pull", text: String(
                localized: "agentHome.prs.noMine", defaultValue: "You have no open pull requests."
            ))
        }
        section(String(localized: "agentHome.prs.needsYou", defaultValue: "Needs you"), actionable, kind: .mine)
        section(String(localized: "agentHome.prs.waiting", defaultValue: "Waiting"), waiting, kind: .mine)
        moreOnGitHub(shown: inbox.mine.count, total: inbox.mineTotal)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [GitHubPullRequest], kind: AgentHomePullRequestRow.Kind) -> some View {
        if !items.isEmpty {
            HStack(spacing: 6) {
                Text(title)
                Text(items.count, format: .number).foregroundStyle(.tertiary)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 4)
            ForEach(items) { pullRequest in
                AgentHomePullRequestRow(
                    pullRequest: pullRequest,
                    kind: kind,
                    linkedThread: model.linkedThreads[pullRequest.key],
                    onOpen: { model.open(pullRequest, tabManager: tabManager) },
                    onOpenInBrowser: { model.openInBrowser(pullRequest) },
                    onReviewWithAgent: { onReviewWithAgent(pullRequest) },
                    onOpenThread: onOpenThread
                )
            }
        }
    }

    @ViewBuilder
    private func moreOnGitHub(shown: Int, total: Int) -> some View {
        if total > shown {
            Text(String(localized: "agentHome.prs.more", defaultValue: "\(total - shown) more on GitHub"))
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.top, 10)
        }
    }
}

/// One pull request: status mark, title, where it lives, and what it's waiting on.
struct AgentHomePullRequestRow: View {
    enum Kind { case review, mine }

    let pullRequest: GitHubPullRequest
    let kind: Kind
    let linkedThread: T3CodeStateReader.PullRequestThread?
    let onOpen: () -> Void
    let onOpenInBrowser: () -> Void
    let onReviewWithAgent: () -> Void
    let onOpenThread: (T3CodeStateReader.PullRequestThread) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            statusMark
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(pullRequest.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if pullRequest.isDraft {
                        AgentHomePRChip(text: String(localized: "agentHome.prs.draft", defaultValue: "Draft"), color: .secondary)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            if isHovered {
                actions.transition(.opacity)
            } else {
                chips.transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.05 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
        .help(pullRequest.url)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var subtitle: String {
        var parts = ["\(pullRequest.repository)#\(pullRequest.number)"]
        if kind == .review, let author = pullRequest.author { parts.append(author) }
        if let updated = pullRequest.updatedAt { parts.append(AgentHomeFormat.relative(updated)) }
        parts.append("+\(pullRequest.additions) −\(pullRequest.deletions)")
        return parts.joined(separator: " · ")
    }

    /// The leading mark: what this pull request needs, at a glance.
    private var statusMark: some View {
        let (symbol, color): (String, Color) = {
            switch kind {
            case .review:
                return pullRequest.viewerReviewState == nil
                    ? ("eye", AgentHomePalette.running)
                    : ("arrow.uturn.backward", AgentHomePalette.running)
            case .mine:
                switch pullRequest.nextStep {
                case .fixConflicts, .fixChecks: return ("exclamationmark", .red)
                case .addressReview: return ("text.bubble", AgentHomePalette.needsYou)
                case .merge: return ("checkmark", AgentHomePalette.done)
                case .checksRunning: return ("circle.dotted", .secondary)
                case .awaitingReview: return ("hourglass", .secondary)
                case .draft: return ("pencil", .secondary)
                }
            }
        }()
        return Image(systemName: symbol)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 24, height: 24)
            .background(Circle().fill(color.opacity(0.13)))
    }

    private var chips: some View {
        HStack(spacing: 6) {
            if pullRequest.comments > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left").font(.system(size: 9.5))
                    Text(pullRequest.comments, format: .number)
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
            if linkedThread != nil {
                AgentHomePRChip(text: "T3", color: AgentHomePalette.running)
            }
            if kind == .mine, let step = stepText {
                AgentHomePRChip(text: step.0, color: step.1)
            }
            checksMark
        }
    }

    private var stepText: (String, Color)? {
        switch pullRequest.nextStep {
        case .fixConflicts: return (String(localized: "agentHome.prs.conflicts", defaultValue: "Conflicts"), .red)
        case .fixChecks: return (String(localized: "agentHome.prs.checksFailing", defaultValue: "Checks failing"), .red)
        case .addressReview: return (String(localized: "agentHome.prs.changesRequested", defaultValue: "Changes requested"), AgentHomePalette.needsYou)
        case .merge: return (String(localized: "agentHome.prs.readyToMerge", defaultValue: "Ready to merge"), AgentHomePalette.done)
        case .checksRunning: return (String(localized: "agentHome.prs.checksRunning", defaultValue: "Checks running"), .secondary)
        case .awaitingReview: return (String(localized: "agentHome.prs.awaitingReview", defaultValue: "Awaiting review"), .secondary)
        case .draft: return nil
        }
    }

    @ViewBuilder
    private var checksMark: some View {
        switch pullRequest.checks {
        case .passing:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(AgentHomePalette.done)
                .help(String(localized: "agentHome.prs.checksPassed", defaultValue: "Checks passed"))
        case .failing:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                .help(String(localized: "agentHome.prs.checksFailing", defaultValue: "Checks failing"))
        case .running:
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                .help(String(localized: "agentHome.prs.checksRunning", defaultValue: "Checks running"))
        case .none:
            Color.clear.frame(width: 12)
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if let linkedThread {
                AgentHomePRAction(
                    symbol: "bubble.left.and.text.bubble.right",
                    help: String(localized: "agentHome.prs.openThread", defaultValue: "Open the T3 thread: \(linkedThread.title)")
                ) { onOpenThread(linkedThread) }
            }
            if kind == .review {
                AgentHomePRAction(
                    symbol: "sparkles",
                    title: String(localized: "agentHome.prs.reviewWithAgent", defaultValue: "Review with agent"),
                    help: String(localized: "agentHome.prs.reviewWithAgent.help", defaultValue: "Start a T3 chat that reviews this pull request")
                ) { onReviewWithAgent() }
            }
            AgentHomePRAction(
                symbol: "arrow.up.right",
                help: String(localized: "agentHome.prs.openInBrowser", defaultValue: "Open in your browser")
            ) { onOpenInBrowser() }
        }
    }
}

private struct AgentHomePRChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.13)))
    }
}

private struct AgentHomePRAction: View {
    let symbol: String
    var title: String?
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                if let title { Text(title).font(.system(size: 11.5, weight: .medium)) }
            }
            .padding(.horizontal, title == nil ? 6 : 9)
            .frame(height: 24)
            .background(Capsule().fill(Color.primary.opacity(isHovered ? 0.12 : 0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

private struct AgentHomePullRequestsEmpty: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 22, weight: .light)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }
}

/// The sidebar row that opens the pull requests list.
struct AgentHomePullRequestsSidebarRow: View {
    let isSelected: Bool
    let reviewCount: Int
    let actionableCount: Int
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(String(localized: "agentHome.prs.title", defaultValue: "Pull requests"))
                    .font(.system(size: 13))
                Spacer(minLength: 4)
                if actionableCount > 0 {
                    Text(actionableCount, format: .number)
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(AgentHomePalette.needsYou)
                        .help(String(localized: "agentHome.prs.actionableHelp", defaultValue: "\(actionableCount) of yours need you"))
                }
                if reviewCount > 0 {
                    Text(reviewCount, format: .number)
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(Capsule().fill(AgentHomePalette.running))
                        .help(String(localized: "agentHome.prs.reviewHelp", defaultValue: "\(reviewCount) waiting on your review"))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.09 : (isHovered ? 0.05 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
    }
}
