import AppKit
import CmuxAgentHome
import SwiftUI

// MARK: - Relationships

/// How the thread on screen relates to the rest of its task, as in T3's
/// Relationships panel: where it was handed off from and to, its parent or
/// fork source, and the sub-threads it created. Each row opens that thread.
struct AgentHomeT3RelationshipsCard: View {
    let thread: T3Thread
    let task: T3TaskNode
    /// A thread's title, for threads outside the task too; `nil` when T3 no longer lists it.
    let title: (String) -> String?
    let onOpen: (String) -> Void

    struct Relation: Identifiable, Hashable {
        enum Kind { case handedOffFrom, handedOffTo, parent, forkedFrom, subThread, fork }
        var kind: Kind
        var threadId: String
        var id: String { "\(kind)-\(threadId)" }
    }

    static func relations(of thread: T3Thread, in task: T3TaskNode) -> [Relation] {
        var relations: [Relation] = []
        if let launcher = thread.launchedByThreadId {
            relations.append(Relation(kind: .handedOffFrom, threadId: launcher))
        }
        if let parent = thread.parentThreadId {
            relations.append(Relation(kind: thread.relationshipToParent == "fork" ? .forkedFrom : .parent, threadId: parent))
        }
        for other in task.allThreads where other.id != thread.id {
            if other.launchedByThreadId == thread.id {
                relations.append(Relation(kind: .handedOffTo, threadId: other.id))
            } else if other.parentThreadId == thread.id {
                relations.append(Relation(kind: other.relationshipToParent == "fork" ? .fork : .subThread, threadId: other.id))
            }
        }
        return relations
    }

    var body: some View {
        let relations = Self.relations(of: thread, in: task)
        if !relations.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                AgentHomeSectionHeader(
                    title: String(localized: "agentHome.t3.relationships", defaultValue: "Relationships"),
                    detail: thread.title
                )
                VStack(spacing: 0) {
                    ForEach(relations) { relation in
                        AgentHomeT3RelationRow(
                            relation: relation,
                            title: title(relation.threadId),
                            status: task.thread(withId: relation.threadId).map(T3ThreadStatus.of),
                            onOpen: { onOpen(relation.threadId) }
                        )
                        if relation != relations.last { Divider().opacity(0.5).padding(.leading, 34) }
                    }
                }
                .agentHomeCard()
            }
        }
    }
}

private struct AgentHomeT3RelationRow: View {
    let relation: AgentHomeT3RelationshipsCard.Relation
    let title: String?
    let status: T3ThreadStatus?
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 11)).foregroundStyle(.tertiary)
                    Text(title ?? String(localized: "agentHome.t3.relation.gone", defaultValue: "A thread T3 no longer lists"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(title == nil ? .tertiary : .primary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let status { AgentHomeT3StatusDot(status: status, showsDone: true) }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(isHovered && title != nil ? 0.04 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(title == nil)
        .onHover { isHovered = $0 }
    }

    private var symbol: String {
        switch relation.kind {
        case .handedOffFrom: return "arrowshape.turn.up.left"
        case .handedOffTo: return "arrowshape.turn.up.right"
        case .parent: return "arrow.up.left"
        case .forkedFrom, .fork: return "arrow.triangle.branch"
        case .subThread: return "arrow.turn.down.right"
        }
    }

    private var label: String {
        switch relation.kind {
        case .handedOffFrom: return String(localized: "agentHome.t3.relation.handedOffFrom", defaultValue: "Handed off from")
        case .handedOffTo: return String(localized: "agentHome.t3.relation.handedOffTo", defaultValue: "Handed off to")
        case .parent: return String(localized: "agentHome.t3.relation.parent", defaultValue: "Parent thread")
        case .forkedFrom: return String(localized: "agentHome.t3.relation.forkedFrom", defaultValue: "Forked from")
        case .subThread: return String(localized: "agentHome.t3.relation.subThread", defaultValue: "Sub-thread")
        case .fork: return String(localized: "agentHome.t3.relation.fork", defaultValue: "Fork")
        }
    }
}

// MARK: - Linked pull requests

/// The pull requests a T3 task's threads linked, as in T3's "Linked pull
/// requests" panel: chains of pull requests based on each other, each with its
/// state, checks, review, conflicts, size and branches, and one next step.
struct AgentHomeT3LinkedPullRequests: View {
    let task: T3TaskNode
    let workspaceId: UUID?
    @ObservedObject var tabManager: TabManager
    /// Starts a new chat in the task's project with a prompt (Resolve, Fix).
    let onStartChat: (String) -> Void
    let onOpenThread: (String) -> Void

    @State private var confirmingMerge: T3Thread.PullRequest?
    private let actions = AgentHomeT3PullRequestActions.shared

    var body: some View {
        let chains = T3PullRequestPanel.chains(for: task.allThreads)
        let entries = chains.flatMap(\.entries)
        let openCount = entries.filter { $0.pullRequest.status == .open }.count
        VStack(alignment: .leading, spacing: 9) {
            AgentHomeSectionHeader(
                title: String(localized: "agentHome.t3.linkedPullRequests", defaultValue: "Linked pull requests"),
                detail: entries.isEmpty ? nil : "\(entries.count)"
            )
            if entries.isEmpty {
                Text(String(localized: "agentHome.t3.linkedPullRequests.empty", defaultValue: "No pull requests linked yet. Agents link the ones they open."))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .agentHomeCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(chains) { chain in
                        ForEach(chain.entries) { entry in
                            AgentHomeT3PullRequestRow(
                                entry: entry,
                                isPending: actions.pending.contains(entry.id),
                                outcome: actions.outcomes[entry.id],
                                onOpen: {
                                    withAnimation(.easeOut(duration: 0.16)) {
                                        AgentHomeTaskViewState.shared.showPullRequest(GitHubPullRequestRef(repository: entry.pullRequest.repository, number: entry.pullRequest.number))
                                    }
                                },
                                onOpenBeside: { actions.open(entry.pullRequest, inWorkspace: workspaceId, tabManager: tabManager) },
                                onStep: { step in perform(step, on: entry.pullRequest) },
                                onOpenThread: { onOpenThread(entry.threadId) }
                            )
                            if entry != entries.last { Divider().opacity(0.5) }
                        }
                    }
                }
                .agentHomeCard()
                footer(openCount: openCount, linkedCount: entries.count, synced: entries.compactMap(\.pullRequest.syncedAt).max())
            }
        }
        .alert(
            String(localized: "agentHome.t3.pr.mergeTitle", defaultValue: "Merge pull request?"),
            isPresented: Binding(get: { confirmingMerge != nil }, set: { if !$0 { confirmingMerge = nil } }),
            presenting: confirmingMerge
        ) { pullRequest in
            Button(String(localized: "agentHome.t3.pr.merge", defaultValue: "Merge")) {
                actions.run(.merge, on: pullRequest)
            }
            Button(String(localized: "agentHome.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: { pullRequest in
            Text(String(
                localized: "agentHome.t3.pr.mergeMessage",
                defaultValue: "This merges #\(pullRequest.number) into \(pullRequest.baseBranch ?? "its base branch") on GitHub."
            ))
        }
    }

    private func perform(_ step: T3PullRequestNextStep, on pullRequest: T3Thread.PullRequest) {
        if let prompt = step.prompt(for: pullRequest) {
            onStartChat(prompt)
        } else if step == .merge {
            confirmingMerge = pullRequest
        } else {
            actions.run(step, on: pullRequest)
        }
    }

    private func footer(openCount: Int, linkedCount: Int, synced: Date?) -> some View {
        var parts = [
            String(localized: "agentHome.t3.pr.openCount", defaultValue: "\(openCount) open"),
            String(localized: "agentHome.t3.pr.linkedCount", defaultValue: "\(linkedCount) linked"),
        ]
        if let synced {
            parts.append(String(localized: "agentHome.t3.pr.synced", defaultValue: "synced \(AgentHomeFormat.relative(synced))"))
        }
        return Text(parts.joined(separator: " · "))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.leading, 2)
    }
}

private struct AgentHomeT3PullRequestRow: View {
    let entry: T3PullRequestEntry
    let isPending: Bool
    let outcome: AgentHomeT3PullRequestActions.Outcome?
    let onOpen: () -> Void
    /// Opens the GitHub page in a browser beside the task's terminal.
    let onOpenBeside: () -> Void
    let onStep: (T3PullRequestNextStep) -> Void
    let onOpenThread: () -> Void

    @State private var isHovered = false

    private var pullRequest: T3Thread.PullRequest { entry.pullRequest }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if entry.depth > 0 {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
            AgentHomeT3PullRequestStateGlyph(pullRequest: pullRequest)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(verbatim: "#\(pullRequest.number)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(pullRequest.title ?? pullRequest.repository)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(2)
                }
                statusLine
                if let head = pullRequest.headBranch {
                    Text(verbatim: "\(head) → \(pullRequest.baseBranch ?? "")")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let outcome {
                    Text(outcome.message)
                        .font(.system(size: 11))
                        .foregroundStyle(outcome.failed ? Color.red : AgentHomePalette.done)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            if let step = pullRequest.nextStep {
                stepButton(step)
            }
        }
        .padding(.leading, CGFloat(entry.depth) * 12)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(isHovered ? 0.04 : 0))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovered = $0 }
        .help(helpText)
        .contextMenu {
            Button(String(localized: "agentHome.t3.pr.openDetail", defaultValue: "Open pull request"), action: onOpen)
            Button(String(localized: "agentHome.t3.pr.openBeside", defaultValue: "Open on GitHub beside the terminal"), action: onOpenBeside)
            if let url = pullRequest.url {
                Button(String(localized: "agentHome.prs.openInBrowser", defaultValue: "Open in your browser")) { NSWorkspace.shared.open(url) }
                Button(String(localized: "agentHome.t3.pr.copyLink", defaultValue: "Copy link")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            Button(String(localized: "agentHome.t3.pr.openLinkingThread", defaultValue: "Open the thread that linked it"), action: onOpenThread)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 7) {
            if pullRequest.status == .open {
                if let checks = pullRequest.checks {
                    label(
                        symbol: checks == .passing ? "checkmark.circle.fill" : checks == .failing ? "xmark.circle.fill" : "clock.fill",
                        color: checks == .passing ? AgentHomePalette.done : checks == .failing ? .red : AgentHomePalette.needsYou,
                        text: checks == .passing
                            ? String(localized: "agentHome.t3.pr.checksPassing", defaultValue: "Checks")
                            : checks == .failing
                                ? String(localized: "agentHome.t3.pr.checksFailing", defaultValue: "Failing")
                                : String(localized: "agentHome.t3.pr.checksPending", defaultValue: "Running")
                    )
                }
                if let review = pullRequest.review {
                    label(
                        symbol: review == .approved ? "person.crop.circle.badge.checkmark" : review == .changesRequested ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle.badge.clock",
                        color: review == .approved ? AgentHomePalette.done : review == .changesRequested ? .red : .secondary,
                        text: review == .approved
                            ? String(localized: "agentHome.t3.pr.approved", defaultValue: "Approved")
                            : review == .changesRequested
                                ? String(localized: "agentHome.t3.pr.changesRequested", defaultValue: "Changes")
                                : String(localized: "agentHome.t3.pr.reviewRequired", defaultValue: "Review")
                    )
                }
                if pullRequest.isConflicting {
                    label(symbol: "exclamationmark.triangle.fill", color: AgentHomePalette.needsYou,
                          text: String(localized: "agentHome.t3.pr.conflicts", defaultValue: "Conflicts"))
                }
            }
            if let additions = pullRequest.additions, let deletions = pullRequest.deletions {
                HStack(spacing: 3) {
                    Text(verbatim: "+\(additions)").foregroundStyle(AgentHomePalette.done)
                    Text(verbatim: "−\(deletions)").foregroundStyle(.red.opacity(0.85))
                }
                .font(.system(size: 10.5, design: .monospaced))
            }
            if let author = pullRequest.author {
                Text(author).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }

    private func label(symbol: String, color: Color, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9.5)).foregroundStyle(color)
            Text(text).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }

    private func stepButton(_ step: T3PullRequestNextStep) -> some View {
        let title: String
        let help: String
        switch step {
        case .resolveConflicts:
            title = String(localized: "agentHome.t3.pr.resolve", defaultValue: "Resolve")
            help = String(localized: "agentHome.t3.pr.resolveHelp", defaultValue: "Resolve the conflicts in a new chat")
        case .markReady:
            title = isPending
                ? String(localized: "agentHome.t3.pr.marking", defaultValue: "Marking…")
                : String(localized: "agentHome.t3.pr.ready", defaultValue: "Ready")
            help = String(localized: "agentHome.t3.pr.readyHelp", defaultValue: "Mark this pull request ready for review")
        case .fixChecks:
            title = String(localized: "agentHome.t3.pr.fix", defaultValue: "Fix")
            help = String(localized: "agentHome.t3.pr.fixHelp", defaultValue: "Fix the failing checks in a new chat")
        case .merge:
            title = isPending
                ? String(localized: "agentHome.t3.pr.merging", defaultValue: "Merging…")
                : String(localized: "agentHome.t3.pr.merge", defaultValue: "Merge")
            help = String(localized: "agentHome.t3.pr.mergeHelp", defaultValue: "Merge this pull request on GitHub")
        }
        let tint: Color = step.startsChat ? AgentHomePalette.needsYou : AgentHomePalette.done
        return Button { onStep(step) } label: {
            HStack(spacing: 3) {
                Text(title)
                if step.startsChat { Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .bold)) }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(tint.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .disabled(isPending)
        .help(help)
    }

    private var helpText: String {
        var parts = ["\(pullRequest.repository)#\(pullRequest.number)"]
        if let source = pullRequest.source {
            let how: String = switch source {
            case "manual": String(localized: "agentHome.t3.pr.source.manual", defaultValue: "Linked by you")
            case "created": String(localized: "agentHome.t3.pr.source.created", defaultValue: "Opened from this task")
            case "stack": String(localized: "agentHome.t3.pr.source.stack", defaultValue: "Part of a linked stack")
            default: String(localized: "agentHome.t3.pr.source.agent", defaultValue: "Linked by the agent")
            }
            parts.append(how)
        }
        if let linked = pullRequest.linkedAt { parts.append(AgentHomeFormat.relative(linked)) }
        return parts.joined(separator: " · ")
    }
}

/// A pull request's state at a glance: open, draft, merged, closed, or open with conflicts.
struct AgentHomeT3PullRequestStateGlyph: View {
    let pullRequest: T3Thread.PullRequest

    static let merged = AgentHomePalette.purple

    var body: some View {
        let (symbol, color): (String, Color) = switch pullRequest.status {
        case .merged: ("arrow.triangle.merge", Self.merged)
        case .closed: ("xmark.circle", AgentHomePalette.danger)
        case .open where pullRequest.isDraft: ("circle.dashed", .secondary)
        case .open where pullRequest.isConflicting: ("arrow.triangle.pull", AgentHomePalette.needsYou)
        case .open: ("arrow.triangle.pull", AgentHomePalette.done)
        case nil: ("arrow.triangle.pull", .secondary)
        }
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 16)
    }
}
