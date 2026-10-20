import AppKit
import CmuxAgentHome
import SwiftUI

/// A pull request inside cmux, laid out like T3's detail panel: a header with
/// one primary action and an overflow menu, then Summary, Timeline and Code.
struct AgentHomePullRequestDetailView: View {
    let ref: GitHubPullRequestRef
    @ObservedObject var tabManager: TabManager

    enum Tab: String, CaseIterable { case summary, timeline, code }

    @State private var tab: Tab = .summary
    @State private var newestFirst = true
    @State private var confirmingMerge: GitHubPullRequestDetail.MergeMethod?
    @State private var confirmingClose = false
    @AppStorage("agentHomePullRequestMergeMethod") private var preferredMergeMethod = ""

    private let model = AgentHomePullRequestDetailModel.shared
    private let viewState = AgentHomeTaskViewState.shared
    private let t3Model = AgentHomeT3Model.shared

    var body: some View {
        let entry = model.entry(for: ref)
        VStack(spacing: 0) {
            if let detail = entry.detail {
                header(detail, entry: entry)
                tabBar(detail, entry: entry)
                Divider().opacity(0.6)
                ScrollView(.vertical) {
                    Group {
                        switch tab {
                        case .summary: AgentHomePRSummaryTab(detail: detail, onLink: openLink, onFixCheck: { startChat(.fixChecks, detail) })
                        case .timeline: AgentHomePRTimelineTab(detail: detail, newestFirst: newestFirst, onLink: openLink, onShowCode: { tab = .code })
                        case .code: AgentHomePRCodeTab(ref: ref, detail: detail, files: entry.files, filesError: entry.filesError, onLink: openLink)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(maxWidth: 1100, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.automatic)
                if tab != .code {
                    AgentHomePRComposer(detail: detail, isPending: model.pending[ref.id] != nil) { action in
                        model.run(action, on: ref)
                    }
                }
            } else if let error = entry.error {
                VStack(spacing: 10) {
                    backButton
                    Text(error).foregroundStyle(.secondary)
                    Button(String(localized: "agentHome.pr.retry", defaultValue: "Try again")) { model.load(ref, force: true) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: "\(ref.repository)#\(ref.number)").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task(id: ref) { model.load(ref) }
        .alert(
            String(localized: "agentHome.t3.pr.mergeTitle", defaultValue: "Merge pull request?"),
            isPresented: Binding(get: { confirmingMerge != nil }, set: { if !$0 { confirmingMerge = nil } }),
            presenting: confirmingMerge
        ) { method in
            Button(Self.mergeLabel(method)) { model.run(.merge(method), on: ref) }
            Button(String(localized: "agentHome.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: { method in
            Text(String(localized: "agentHome.pr.mergeMessage", defaultValue: "This merges #\(ref.number) on GitHub using \(Self.mergeLabel(method).lowercased())."))
        }
        .alert(
            String(localized: "agentHome.pr.closeTitle", defaultValue: "Close pull request?"),
            isPresented: $confirmingClose
        ) {
            Button(String(localized: "agentHome.pr.close", defaultValue: "Close"), role: .destructive) { model.run(.close, on: ref) }
            Button(String(localized: "agentHome.cancel", defaultValue: "Cancel"), role: .cancel) {}
        }
    }

    // MARK: - Header

    private var backButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { viewState.goBackFromPullRequest() }
        } label: {
            Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(String(localized: "agentHome.pr.back", defaultValue: "Back"))
        .keyboardShortcut("[", modifiers: .command)
    }

    private func header(_ detail: GitHubPullRequestDetail, entry: AgentHomePullRequestDetailModel.Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                backButton
                Text(detail.ref.repository).foregroundStyle(.secondary)
                Button {
                    if let url = detail.url { openLink(url) }
                } label: {
                    Text(verbatim: "#\(detail.ref.number)")
                        .fontWeight(.semibold)
                        .foregroundStyle(AgentHomePRStateStyle(detail: detail).color)
                }
                .buttonStyle(.plain)
                .help(String(localized: "agentHome.pr.openOnGitHub", defaultValue: "Open on GitHub"))
                if entry.isLoading { ProgressView().controlSize(.mini) }
                Spacer(minLength: 8)
                if let pending = model.pending[ref.id] {
                    Text(pending).font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else if let outcome = model.outcomes[ref.id] {
                    Text(outcome.message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(outcome.failed ? Color.red : AgentHomePalette.done)
                        .lineLimit(1)
                }
                primaryControl(detail)
                overflowMenu(detail)
            }
            .font(.system(size: 12.5))

            Text(detail.title)
                .font(.system(size: 17, weight: .semibold))
                .textSelection(.enabled)
                .lineLimit(3)

            HStack(spacing: 10) {
                AgentHomePRStateBadge(detail: detail)
                if let author = detail.author {
                    AgentHomeAvatar(actor: author, size: 16)
                    Text(author.login).foregroundStyle(.secondary)
                }
                if let updated = detail.updatedAt {
                    Text(String(localized: "agentHome.pr.updated", defaultValue: "updated \(AgentHomePRFormat.ago(updated))")).foregroundStyle(.tertiary)
                }
                HStack(spacing: 4) {
                    Text(detail.baseBranch)
                    Text(verbatim: "←").foregroundStyle(.tertiary)
                    Text(detail.headBranch)
                }
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                if detail.isOpen, detail.isBehind {
                    Label(String(localized: "agentHome.pr.behind", defaultValue: "Behind \(detail.baseBranch)"), systemImage: "arrow.down.circle")
                        .foregroundStyle(AgentHomePalette.needsYou)
                }
                Spacer(minLength: 8)
                Text(String(localized: "agentHome.pr.files", defaultValue: "\(detail.changedFiles) files")).foregroundStyle(.secondary)
                Text(verbatim: "+\(detail.additions)").foregroundStyle(AgentHomePalette.done).font(.system(size: 11.5, design: .monospaced))
                Text(verbatim: "−\(detail.deletions)").foregroundStyle(.red.opacity(0.85)).font(.system(size: 11.5, design: .monospaced))
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func primaryControl(_ detail: GitHubPullRequestDetail) -> some View {
        let isPending = model.pending[ref.id] != nil
        switch detail.primaryAction {
        case .state:
            EmptyView()
        case .resolveConflicts:
            AgentHomePRButton(title: String(localized: "agentHome.pr.resolveConflicts", defaultValue: "Resolve conflicts"), systemImage: "arrow.up.right", tint: .red) {
                startChat(.resolveConflicts, detail)
            }
            .help(String(localized: "agentHome.t3.pr.resolveHelp", defaultValue: "Resolve the conflicts in a new chat"))
        case .readyForReview:
            AgentHomePRButton(title: String(localized: "agentHome.pr.readyForReview", defaultValue: "Ready for review"), tint: AgentHomePalette.running) {
                model.run(.ready, on: ref)
            }
            .disabled(isPending)
        case .autoMergeEnabled:
            Label(String(localized: "agentHome.pr.autoMerge", defaultValue: "Auto-merge on"), systemImage: "clock.arrow.circlepath")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(AgentHomePalette.done)
        case .merge(let fallback):
            let method = mergeMethod(detail) ?? fallback
            AgentHomePRButton(title: Self.mergeLabel(method), tint: AgentHomePalette.done) {
                confirmingMerge = method
            }
            .disabled(isPending)
        case .none:
            EmptyView()
        }
    }

    private func overflowMenu(_ detail: GitHubPullRequestDetail) -> some View {
        Menu {
            Button(String(localized: "agentHome.prs.reviewWithAgent", defaultValue: "Review with agent")) {
                openChat(AgentHomePullRequestsModel.reviewPrompt(url: detail.url?.absoluteString ?? ""), detail)
            }
            if detail.checksState == .failing {
                Button(String(localized: "agentHome.pr.fixChecks", defaultValue: "Fix failing checks")) { startChat(.fixChecks, detail) }
            }
            Button(String(localized: "agentHome.pr.refresh", defaultValue: "Refresh")) { model.load(ref, force: true) }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            if detail.isOpen {
                if detail.isDraft {
                    Button(String(localized: "agentHome.pr.readyForReview", defaultValue: "Ready for review")) { model.run(.ready, on: ref) }
                } else {
                    Button(String(localized: "agentHome.pr.convertToDraft", defaultValue: "Convert to draft")) { model.run(.draft, on: ref) }
                }
                if !detail.allowedMergeMethods.isEmpty {
                    Picker(String(localized: "agentHome.pr.mergeMethod", defaultValue: "Merge method"), selection: Binding(
                        get: { mergeMethod(detail) ?? detail.allowedMergeMethods[0] },
                        set: { preferredMergeMethod = $0.rawValue }
                    )) {
                        ForEach(detail.allowedMergeMethods, id: \.self) { method in
                            Text(Self.mergeLabel(method)).tag(method)
                        }
                    }
                    .pickerStyle(.inline)
                }
                Divider()
            }
            Button(String(localized: "agentHome.pr.openOnGitHub", defaultValue: "Open on GitHub")) { if let url = detail.url { openLink(url) } }
            Button(String(localized: "agentHome.t3.pr.copyLink", defaultValue: "Copy link")) { copy(detail.url?.absoluteString ?? "") }
            Button(String(localized: "agentHome.pr.copyNumber", defaultValue: "Copy PR number")) { copy("#\(detail.ref.number)") }
            Divider()
            if detail.state == .open {
                Button(String(localized: "agentHome.pr.closeEllipsis", defaultValue: "Close pull request…"), role: .destructive) { confirmingClose = true }
            } else if detail.state == .closed {
                Button(String(localized: "agentHome.pr.reopen", defaultValue: "Reopen pull request")) { model.run(.reopen, on: ref) }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func tabBar(_ detail: GitHubPullRequestDetail, entry: AgentHomePullRequestDetailModel.Entry) -> some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab) {
                Text(String(localized: "agentHome.pr.tab.summary", defaultValue: "Summary")).tag(Tab.summary)
                Text(String(localized: "agentHome.pr.tab.timeline", defaultValue: "Timeline")).tag(Tab.timeline)
                Text(entry.files.map { String(localized: "agentHome.pr.tab.codeCount", defaultValue: "Code · \($0.count)") }
                    ?? String(localized: "agentHome.pr.tab.code", defaultValue: "Code")).tag(Tab.code)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            switch tab {
            case .summary:
                AgentHomePRChecksLine(detail: detail)
            case .timeline:
                Text(String(localized: "agentHome.pr.timelineCounts", defaultValue: "\(detail.comments.count) comments · \(detail.commits.count) commits"))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Button(newestFirst
                    ? String(localized: "agentHome.pr.newestFirst", defaultValue: "Newest first")
                    : String(localized: "agentHome.pr.oldestFirst", defaultValue: "Oldest first")) { newestFirst.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            case .code:
                if let files = entry.files {
                    Text(String(localized: "agentHome.pr.viewedCount", defaultValue: "\(model.viewedCount(files, in: ref)) / \(files.count) viewed"))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
    }

    // MARK: - Helpers

    private func mergeMethod(_ detail: GitHubPullRequestDetail) -> GitHubPullRequestDetail.MergeMethod? {
        GitHubPullRequestDetail.MergeMethod(rawValue: preferredMergeMethod).flatMap { detail.allowedMergeMethods.contains($0) ? $0 : nil }
    }

    static func mergeLabel(_ method: GitHubPullRequestDetail.MergeMethod) -> String {
        switch method {
        case .merge: String(localized: "agentHome.pr.merge.merge", defaultValue: "Merge")
        case .squash: String(localized: "agentHome.pr.merge.squash", defaultValue: "Squash and merge")
        case .rebase: String(localized: "agentHome.pr.merge.rebase", defaultValue: "Rebase and merge")
        }
    }

    private func openLink(_ url: URL) {
        model.openLink(url, from: ref, title: model.entry(for: ref).detail?.title ?? "", tabManager: tabManager)
    }

    private func startChat(_ step: T3PullRequestNextStep, _ detail: GitHubPullRequestDetail) {
        let linked = T3Thread.PullRequest(
            repository: detail.ref.repository, number: detail.ref.number, url: detail.url,
            title: detail.title, headBranch: detail.headBranch, baseBranch: detail.baseBranch
        )
        if let prompt = step.prompt(for: linked) { openChat(prompt, detail) }
    }

    private func openChat(_ prompt: String, _ detail: GitHubPullRequestDetail) {
        t3Model.openNewChat(
            projectId: AgentHomePullRequestsModel.shared.project(forRepository: detail.ref.repository)?.id,
            text: prompt,
            tabManager: tabManager
        )
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Summary

private struct AgentHomePRSummaryTab: View {
    let detail: GitHubPullRequestDetail
    let onLink: (URL) -> Void
    let onFixCheck: () -> Void

    @State private var showsChecks = false
    @State private var showsDescription = true
    @State private var showsBots = true
    @State private var commentLimit = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !detail.reviewers.isEmpty || !detail.labels.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    if !detail.reviewers.isEmpty {
                        HStack(spacing: 10) {
                            Text(String(localized: "agentHome.pr.reviewers", defaultValue: "Reviewers")).foregroundStyle(.tertiary).frame(width: 74, alignment: .leading)
                            FlowRow(spacing: 6) {
                                ForEach(detail.reviewers) { AgentHomePRReviewerChip(reviewer: $0) }
                            }
                        }
                    }
                    if !detail.labels.isEmpty {
                        HStack(spacing: 10) {
                            Text(String(localized: "agentHome.pr.labels", defaultValue: "Labels")).foregroundStyle(.tertiary).frame(width: 74, alignment: .leading)
                            FlowRow(spacing: 6) {
                                ForEach(detail.labels) { AgentHomePRLabelChip(label: $0) }
                            }
                        }
                    }
                }
                .font(.system(size: 12))
            }

            AgentHomePRSection(title: String(localized: "agentHome.pr.description", defaultValue: "Description"), isExpanded: $showsDescription) {
                if detail.bodyHTML.isEmpty {
                    Text(String(localized: "agentHome.pr.noDescription", defaultValue: "No description provided.")).italic().foregroundStyle(.tertiary)
                } else {
                    AgentHomeHTMLBlock(html: detail.bodyHTML, onLink: onLink)
                }
            }

            if !detail.checks.isEmpty {
                AgentHomePRSection(
                    title: String(localized: "agentHome.pr.checks", defaultValue: "Checks"),
                    detail: AgentHomePRChecksLine.summaryText(detail),
                    isExpanded: $showsChecks
                ) {
                    VStack(spacing: 0) {
                        ForEach(detail.checks) { check in
                            AgentHomePRCheckRow(check: check, onLink: onLink, onFix: onFixCheck)
                            if check != detail.checks.last { Divider().opacity(0.4) }
                        }
                    }
                    .agentHomeCard()
                }
            }

            let comments = detail.comments.filter { showsBots || $0.author?.isBot != true }.reversed()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    AgentHomeSectionHeader(title: String(localized: "agentHome.pr.comments", defaultValue: "Comments"), detail: "\(detail.comments.count)")
                    Spacer()
                    Toggle(String(localized: "agentHome.pr.showBots", defaultValue: "Bots"), isOn: $showsBots)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                }
                if comments.isEmpty {
                    Text(String(localized: "agentHome.pr.noComments", defaultValue: "No comments yet.")).font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                ForEach(Array(comments.prefix(commentLimit))) { comment in
                    AgentHomePRCommentCard(comment: comment, onLink: onLink)
                }
                if comments.count > commentLimit {
                    Button(String(localized: "agentHome.pr.showOlder", defaultValue: "Show older comments")) { commentLimit += 10 }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AgentHomePalette.running)
                }
            }
        }
    }
}

private struct AgentHomePRSection<Content: View>: View {
    let title: String
    var detail: String?
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                    AgentHomeSectionHeader(title: title, detail: detail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded { content() }
        }
    }
}

private struct AgentHomePRCheckRow: View {
    let check: GitHubPullRequestDetail.Check
    let onLink: (URL) -> Void
    let onFix: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            AgentHomePRCheckIcon(status: check.status)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(check.name).font(.system(size: 12.5))
                    if check.isRequired {
                        Text(String(localized: "agentHome.pr.required", defaultValue: "Required")).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                if let workflow = check.workflow ?? check.description {
                    Text(workflow).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text(AgentHomePRCheckIcon.label(check)).font(.system(size: 11.5)).foregroundStyle(.secondary)
            if check.status == .failure {
                Button(String(localized: "agentHome.t3.pr.fix", defaultValue: "Fix"), action: onFix)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AgentHomePalette.needsYou)
            }
            if let url = check.url {
                Button { onLink(url) } label: { Image(systemName: "arrow.up.right.square").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help(String(localized: "agentHome.pr.checkDetails", defaultValue: "Details"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

/// The checks line at the end of the Summary tab bar: an icon and a sentence.
private struct AgentHomePRChecksLine: View {
    let detail: GitHubPullRequestDetail

    var body: some View {
        if let state = detail.checksState {
            HStack(spacing: 5) {
                Image(systemName: state == .passing ? "checkmark.circle.fill" : state == .failing ? "xmark.circle.fill" : "clock.fill")
                    .foregroundStyle(state == .passing ? AgentHomePalette.done : state == .failing ? .red : AgentHomePalette.needsYou)
                Text(Self.summaryText(detail) ?? "")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
    }

    static func summaryText(_ detail: GitHubPullRequestDetail) -> String? {
        let summary = detail.checksSummary
        var parts: [String] = []
        if summary.failing > 0 { parts.append(String(localized: "agentHome.pr.checks.failing", defaultValue: "\(summary.failing) failing")) }
        if summary.running > 0 { parts.append(String(localized: "agentHome.pr.checks.running", defaultValue: "\(summary.running) running")) }
        if summary.passed > 0 { parts.append(String(localized: "agentHome.pr.checks.passed", defaultValue: "\(summary.passed) passed")) }
        if summary.skipped > 0 { parts.append(String(localized: "agentHome.pr.checks.skipped", defaultValue: "\(summary.skipped) skipped")) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

private struct AgentHomePRCheckIcon: View {
    let status: GitHubPullRequestDetail.Check.Status

    var body: some View {
        Group {
            switch status {
            case .pending: Image(systemName: "circle.dotted").foregroundStyle(AgentHomePalette.needsYou)
            case .actionRequired: Image(systemName: "exclamationmark.circle").foregroundStyle(AgentHomePalette.needsYou)
            case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(AgentHomePalette.done)
            case .failure, .cancelled: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .skipped, .neutral: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .frame(width: 14)
    }

    static func label(_ check: GitHubPullRequestDetail.Check) -> String {
        switch check.status {
        case .pending: String(localized: "agentHome.pr.check.running", defaultValue: "Running")
        case .actionRequired:
            check.url?.path.range(of: #"/actions/runs/\d+"#, options: .regularExpression) != nil
                ? String(localized: "agentHome.pr.check.awaitingApproval", defaultValue: "Awaiting approval")
                : String(localized: "agentHome.pr.check.awaitingAction", defaultValue: "Awaiting action")
        case .success: String(localized: "agentHome.pr.check.passed", defaultValue: "Passed")
        case .failure: String(localized: "agentHome.pr.check.failed", defaultValue: "Failed")
        case .cancelled: String(localized: "agentHome.pr.check.cancelled", defaultValue: "Cancelled")
        case .skipped: String(localized: "agentHome.pr.check.skipped", defaultValue: "Skipped")
        case .neutral: String(localized: "agentHome.pr.check.neutral", defaultValue: "Neutral")
        }
    }
}

private struct AgentHomePRCommentCard: View {
    let comment: GitHubPullRequestDetail.Comment
    let onLink: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                if let author = comment.author { AgentHomeAvatar(actor: author, size: 18) }
                Text(comment.author?.login ?? "ghost").font(.system(size: 12, weight: .semibold))
                if comment.author?.isBot == true {
                    Text(verbatim: "bot").font(.system(size: 10)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 4).background(Capsule().strokeBorder(Color.primary.opacity(0.15)))
                }
                if let verdict = comment.verdict { AgentHomePRVerdictLabel(verdict: verdict) }
                if let date = comment.createdAt {
                    Text(AgentHomePRFormat.ago(date)).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                }
                Spacer()
                if let url = comment.url {
                    Button { onLink(url) } label: { Image(systemName: "arrow.up.right.square").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
            if !comment.isEmpty {
                AgentHomeHTMLBlock(html: comment.bodyHTML, onLink: onLink)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .agentHomeCard()
    }
}

// MARK: - Timeline

private struct AgentHomePRTimelineTab: View {
    let detail: GitHubPullRequestDetail
    let newestFirst: Bool
    let onLink: (URL) -> Void
    let onShowCode: () -> Void

    @State private var expandedRuns: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(GitHubPullRequestTimeline.entries(for: detail, newestFirst: newestFirst)) { entry in
                row(entry)
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: GitHubPullRequestTimeline.Entry) -> some View {
        switch entry {
        case .opened(let author, let date):
            event(symbol: "arrow.triangle.pull", color: AgentHomePalette.done,
                  text: String(localized: "agentHome.pr.event.opened", defaultValue: "\(author?.login ?? "Someone") opened this pull request"), date: date)
        case .commit(let commit):
            Button(action: onShowCode) {
                HStack(spacing: 9) {
                    Image(systemName: "smallcircle.filled.circle").font(.system(size: 11)).foregroundStyle(.tertiary).frame(width: 18)
                    Text(commit.headline).font(.system(size: 12.5)).lineLimit(1)
                    Text(commit.shortOid).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    Spacer()
                    if let author = commit.author { Text(author).font(.system(size: 11.5)).foregroundStyle(.tertiary) }
                    if let date = commit.date { Text(AgentHomePRFormat.ago(date)).font(.system(size: 11.5)).foregroundStyle(.tertiary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .comments(let run):
            if run.count == 1 || expandedRuns.contains(entry.id) {
                ForEach(run) { AgentHomePRCommentCard(comment: $0, onLink: onLink) }
            } else {
                Button {
                    expandedRuns.insert(entry.id)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 11)).foregroundStyle(.tertiary).frame(width: 18)
                        Text(String(localized: "agentHome.pr.event.commentRun", defaultValue: "\(run.count) comments · \(Set(run.compactMap { $0.author?.login }).count) authors"))
                            .font(.system(size: 12.5)).foregroundStyle(.secondary)
                        Spacer()
                        if let date = run.last?.createdAt { Text(AgentHomePRFormat.ago(date)).font(.system(size: 11.5)).foregroundStyle(.tertiary) }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        case .review(let review, let isStale):
            if review.isEmpty {
                HStack(spacing: 9) {
                    if let author = review.author { AgentHomeAvatar(actor: author, size: 18) }
                    Text(review.author?.login ?? "ghost").font(.system(size: 12.5, weight: .medium))
                    if let verdict = review.verdict { AgentHomePRVerdictLabel(verdict: verdict) }
                    if isStale { Text(String(localized: "agentHome.pr.stale", defaultValue: "stale")).font(.system(size: 11)).foregroundStyle(.tertiary) }
                    Spacer()
                    if let date = review.createdAt { Text(AgentHomePRFormat.ago(date)).font(.system(size: 11.5)).foregroundStyle(.tertiary) }
                }
            } else {
                AgentHomePRCommentCard(comment: review, onLink: onLink)
            }
        case .merged(let date):
            event(symbol: "arrow.triangle.merge", color: AgentHomeT3PullRequestStateGlyph.merged,
                  text: String(localized: "agentHome.pr.event.merged", defaultValue: "Merged"), date: date)
        case .closed(let date):
            event(symbol: "xmark.circle", color: .red, text: String(localized: "agentHome.pr.event.closed", defaultValue: "Closed"), date: date)
        }
    }

    private func event(symbol: String, color: Color, text: String, date: Date?) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color).frame(width: 18)
            Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary)
            Spacer()
            if let date { Text(AgentHomePRFormat.ago(date)).font(.system(size: 11.5)).foregroundStyle(.tertiary) }
        }
    }
}

// MARK: - Composer

/// Comment, or review with a verdict, as T3's floating composer does.
private struct AgentHomePRComposer: View {
    let detail: GitHubPullRequestDetail
    let isPending: Bool
    let onSubmit: (AgentHomePullRequestDetailModel.Action) -> Void

    @State private var text = ""
    @State private var verdict: AgentHomePullRequestDetailModel.Action.Verdict = .comment

    var body: some View {
        let isAuthor = detail.viewer != nil && detail.viewer == detail.author?.login
        HStack(alignment: .bottom, spacing: 8) {
            TextField(String(localized: "agentHome.pr.commentPlaceholder", defaultValue: "Leave a comment"), text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            if detail.isOpen, !isAuthor {
                Picker("", selection: $verdict) {
                    Text(String(localized: "agentHome.pr.verdict.comment", defaultValue: "Comment")).tag(AgentHomePullRequestDetailModel.Action.Verdict.comment)
                    Text(String(localized: "agentHome.pr.verdict.approve", defaultValue: "Approve")).tag(AgentHomePullRequestDetailModel.Action.Verdict.approve)
                    Text(String(localized: "agentHome.pr.verdict.requestChanges", defaultValue: "Request changes")).tag(AgentHomePullRequestDetailModel.Action.Verdict.requestChanges)
                }
                .labelsHidden()
                .fixedSize()
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            Button(verdict == .comment || isAuthor
                ? String(localized: "agentHome.pr.verdict.comment", defaultValue: "Comment")
                : String(localized: "agentHome.pr.submitReview", defaultValue: "Submit review")) {
                if verdict == .comment || isAuthor {
                    onSubmit(.comment(trimmed))
                } else {
                    onSubmit(.review(verdict: verdict, body: trimmed))
                }
                text = ""
                verdict = .comment
            }
            .disabled(isPending || (trimmed.isEmpty && (verdict != .approve || isAuthor)))
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }
}

// MARK: - Shared pieces

struct AgentHomePRStateStyle {
    let detail: GitHubPullRequestDetail

    var color: Color {
        switch detail.state {
        case .merged: AgentHomeT3PullRequestStateGlyph.merged
        case .closed: .red
        case .open: detail.isDraft ? .secondary : AgentHomePalette.done
        }
    }

    var label: String {
        switch detail.state {
        case .merged: String(localized: "agentHome.pr.merged", defaultValue: "Merged")
        case .closed: String(localized: "agentHome.pr.closed", defaultValue: "Closed")
        case .open: detail.isDraft ? String(localized: "agentHome.prs.draft", defaultValue: "Draft") : String(localized: "agentHome.pr.open", defaultValue: "Open")
        }
    }

    var symbol: String {
        switch detail.state {
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        case .open: detail.isDraft ? "circle.dashed" : "arrow.triangle.pull"
        }
    }
}

private struct AgentHomePRStateBadge: View {
    let detail: GitHubPullRequestDetail

    var body: some View {
        let style = AgentHomePRStateStyle(detail: detail)
        HStack(spacing: 4) {
            Image(systemName: style.symbol).font(.system(size: 10, weight: .semibold))
            Text(style.label).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(style.color))
    }
}

private struct AgentHomePRButton: View {
    let title: String
    var systemImage: String?
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .bold)) }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(Capsule().fill(tint))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct AgentHomeAvatar: View {
    let actor: GitHubActor
    let size: CGFloat

    var body: some View {
        AsyncImage(url: actor.avatarURL.map { URL(string: "\($0.absoluteString)\($0.query == nil ? "?" : "&")s=\(Int(size * 2))") ?? $0 }) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Circle().fill(Color.primary.opacity(0.12))
                .overlay(Text(String(actor.login.prefix(1)).uppercased()).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.secondary))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

private struct AgentHomePRReviewerChip: View {
    let reviewer: GitHubPullRequestDetail.Reviewer

    var body: some View {
        HStack(spacing: 5) {
            AgentHomeAvatar(actor: reviewer.actor, size: 18)
                .overlay(Circle().strokeBorder(ringColor, lineWidth: reviewer.verdict == nil ? 0 : 1.5))
            Text(reviewer.actor.login).foregroundStyle(.secondary)
            if let verdict = reviewer.verdict { AgentHomePRVerdictLabel(verdict: verdict) }
            if reviewer.isStale { Text(String(localized: "agentHome.pr.stale", defaultValue: "stale")).foregroundStyle(.tertiary) }
        }
        .font(.system(size: 11.5))
        .help(reviewer.isStale
            ? String(localized: "agentHome.pr.staleHelp", defaultValue: "This review is older than the latest commit")
            : reviewer.actor.login)
    }

    private var ringColor: Color {
        switch reviewer.verdict {
        case .approved: AgentHomePalette.done
        case .changesRequested: .red
        default: .secondary
        }
    }
}

private struct AgentHomePRVerdictLabel: View {
    let verdict: GitHubPullRequestDetail.Reviewer.Verdict

    var body: some View {
        let (text, color): (String, Color) = switch verdict {
        case .approved: (String(localized: "agentHome.t3.pr.approved", defaultValue: "Approved"), AgentHomePalette.done)
        case .changesRequested: (String(localized: "agentHome.pr.verdict.changesRequested", defaultValue: "Changes requested"), .red)
        case .commented: (String(localized: "agentHome.pr.verdict.commented", defaultValue: "Commented"), .secondary)
        case .dismissed: (String(localized: "agentHome.pr.verdict.dismissed", defaultValue: "Dismissed"), .secondary)
        }
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
    }
}

private struct AgentHomePRLabelChip: View {
    let label: GitHubPullRequestDetail.Label

    var body: some View {
        let color = AgentHomePalette.color(hex: label.color) ?? .secondary
        Text(label.name)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(color.opacity(0.16)))
            .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 0.5))
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// T3's relative times: "just now", "5m ago", "3h ago", "12d ago".
enum AgentHomePRFormat {
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return String(localized: "agentHome.time.justNow", defaultValue: "just now") }
        if seconds < 3600 { return String(localized: "agentHome.time.minutesAgo", defaultValue: "\(Int(seconds / 60))m ago") }
        if seconds < 86_400 { return String(localized: "agentHome.time.hoursAgo", defaultValue: "\(Int(seconds / 3600))h ago") }
        return String(localized: "agentHome.time.daysAgo", defaultValue: "\(Int(seconds / 86_400))d ago")
    }
}
