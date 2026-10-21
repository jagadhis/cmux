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
        .agentHomePageBackground()
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
                    Text(String(localized: "agentHome.pr.updated", defaultValue: "updated \(AgentHomeFormat.relative(updated))")).foregroundStyle(.tertiary)
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
            AgentHomePRButton(title: String(localized: "agentHome.pr.resolveConflicts", defaultValue: "Resolve conflicts"), systemImage: "arrow.up.right", tint: AgentHomePalette.danger) {
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

// MARK: - Composer

/// Comment, or review with a verdict, as T3's floating composer does.
struct AgentHomePRComposer: View {
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
