import AppKit
import CmuxAgentHome
import SwiftUI

/// The Code tab: every changed file in reading order, each a collapsible
/// unified diff with line numbers and its review threads at their lines, as
/// T3's code tab stacks them. Marking a file viewed folds it.
struct AgentHomePRCodeTab: View {
    let ref: GitHubPullRequestRef
    let detail: GitHubPullRequestDetail
    let files: [GitHubPullRequestFile]?
    let filesError: String?
    let onLink: (URL) -> Void

    @State private var collapsed: Set<String> = []
    @State private var didInitialFold = false
    private let model = AgentHomePullRequestDetailModel.shared

    var body: some View {
        if let files {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(String(localized: "agentHome.pr.files", defaultValue: "\(files.count) files")).fontWeight(.semibold)
                    Spacer()
                    Button(collapsed.count == files.count
                        ? String(localized: "agentHome.pr.expandAll", defaultValue: "Expand all")
                        : String(localized: "agentHome.pr.collapseAll", defaultValue: "Collapse all")) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            collapsed = collapsed.count == files.count ? [] : Set(files.map(\.path))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))

                let placed = Set(files.map(\.path))
                let elsewhere = detail.reviewThreads.filter { !placed.contains($0.path) || $0.line == nil }
                if !elsewhere.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        AgentHomeSectionHeader(title: String(localized: "agentHome.pr.otherThreads", defaultValue: "Conversations not on a shown line"), detail: "\(elsewhere.count)")
                        ForEach(elsewhere) { thread in
                            AgentHomePRThreadCard(thread: thread, showsPath: true, onLink: onLink)
                        }
                    }
                }

                ForEach(files) { file in
                    AgentHomePRFileDiff(
                        file: file,
                        threads: detail.reviewThreads.filter { $0.path == file.path && $0.line != nil },
                        viewedState: model.viewedState(of: file, in: ref),
                        isCollapsed: collapsed.contains(file.path),
                        onToggleCollapsed: {
                            withAnimation(.easeOut(duration: 0.15)) {
                                if collapsed.contains(file.path) { collapsed.remove(file.path) } else { collapsed.insert(file.path) }
                            }
                        },
                        onToggleViewed: {
                            let viewed = model.viewedState(of: file, in: ref) != .viewed
                            model.setViewed(viewed, file: file, in: ref)
                            // As in T3, marking a file viewed folds it away.
                            withAnimation(.easeOut(duration: 0.15)) {
                                if viewed { collapsed.insert(file.path) } else { collapsed.remove(file.path) }
                            }
                        },
                        onOpenOnGitHub: { if let url = detail.url?.appendingPathComponent("files") { onLink(url) } },
                        onLink: onLink
                    )
                }
            }
            .onAppear {
                // Files already viewed (and unchanged since) start folded.
                guard !didInitialFold else { return }
                didInitialFold = true
                collapsed = Set(files.filter { model.viewedState(of: $0, in: ref) == .viewed }.map(\.path))
            }
        } else if let filesError {
            Text(filesError).font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        }
    }
}

private struct AgentHomePRFileDiff: View {
    let file: GitHubPullRequestFile
    let threads: [GitHubPullRequestDetail.ReviewThread]
    let viewedState: AgentHomePullRequestDetailModel.ViewedState
    let isCollapsed: Bool
    let onToggleCollapsed: () -> Void
    let onToggleViewed: () -> Void
    let onOpenOnGitHub: () -> Void
    let onLink: (URL) -> Void

    /// Long diffs show this many lines until asked for the rest.
    private static let initialLineLimit = 400
    @State private var showsAllLines = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if !isCollapsed {
                Divider().opacity(0.5)
                diff
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .foregroundStyle(.tertiary)
            statusMark
            VStack(alignment: .leading, spacing: 0) {
                Text(file.path)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                if let previous = file.previousPath {
                    Text(String(localized: "agentHome.pr.renamedFrom", defaultValue: "renamed from \(previous)"))
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                }
            }
            if !threads.isEmpty {
                Label("\(threads.count)", systemImage: "bubble.left").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(verbatim: "+\(file.additions)").font(.system(size: 11, design: .monospaced)).foregroundStyle(AgentHomePalette.done)
            Text(verbatim: "−\(file.deletions)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.red.opacity(0.85))
            Button(action: onToggleViewed) {
                HStack(spacing: 4) {
                    Image(systemName: viewedState == .viewed ? "checkmark.square.fill" : "square")
                        .foregroundStyle(viewedState == .viewed ? AgentHomePalette.running : .secondary)
                    Text(viewedState == .changedSinceViewed
                        ? String(localized: "agentHome.pr.changedSinceViewed", defaultValue: "Changed since viewed")
                        : String(localized: "agentHome.pr.viewed", defaultValue: "Viewed"))
                        .foregroundStyle(viewedState == .changedSinceViewed ? AgentHomePalette.needsYou : .secondary)
                }
                .font(.system(size: 11.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleCollapsed)
        .contextMenu {
            Button(String(localized: "agentHome.pr.copyPath", defaultValue: "Copy path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
            Button(String(localized: "agentHome.pr.openOnGitHub", defaultValue: "Open on GitHub"), action: onOpenOnGitHub)
        }
    }

    private var statusMark: some View {
        let (letter, color): (String, Color) = switch file.status {
        case .added: ("A", AgentHomePalette.done)
        case .removed: ("D", .red)
        case .renamed, .copied: ("R", AgentHomePalette.running)
        default: ("M", AgentHomePalette.needsYou)
        }
        return Text(verbatim: letter)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.14)))
    }

    @ViewBuilder
    private var diff: some View {
        let hunks = file.hunks
        if hunks.isEmpty {
            HStack {
                Text(file.patch == nil
                    ? String(localized: "agentHome.pr.diffUnavailable", defaultValue: "GitHub doesn't show this diff (binary or too large).")
                    : String(localized: "agentHome.pr.noChanges", defaultValue: "No line changes."))
                    .foregroundStyle(.tertiary)
                Button(String(localized: "agentHome.pr.openOnGitHub", defaultValue: "Open on GitHub"), action: onOpenOnGitHub)
                    .buttonStyle(.plain).foregroundStyle(AgentHomePalette.running)
            }
            .font(.system(size: 12))
            .padding(12)
        } else {
            let total = hunks.reduce(0) { $0 + $1.lines.count + 1 }
            let limit = showsAllLines ? Int.max : Self.initialLineLimit
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visibleRows(hunks, limit: limit).enumerated()), id: \.offset) { _, row in
                    switch row {
                    case .header(let header):
                        Text(header)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                            .background(AgentHomePalette.running.opacity(0.07))
                    case .line(let line):
                        AgentHomePRDiffLine(line: line)
                        ForEach(threads.filter { $0.line == line.newNumber && line.kind != .deletion }) { thread in
                            AgentHomePRThreadCard(thread: thread, showsPath: false, onLink: onLink)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                    }
                }
            }
            if total > limit {
                Button(String(localized: "agentHome.pr.showAllLines", defaultValue: "Show all \(total) lines")) { showsAllLines = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AgentHomePalette.running)
                    .padding(10)
            }
        }
    }

    private enum Row { case header(String), line(GitHubDiffHunk.Line) }

    private func visibleRows(_ hunks: [GitHubDiffHunk], limit: Int) -> [Row] {
        var rows: [Row] = []
        for hunk in hunks {
            guard rows.count < limit else { break }
            rows.append(.header(hunk.header))
            for line in hunk.lines {
                guard rows.count < limit else { break }
                rows.append(.line(line))
            }
        }
        return rows
    }
}

private struct AgentHomePRDiffLine: View {
    let line: GitHubDiffHunk.Line

    var body: some View {
        HStack(spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(verbatim: marker)
                .foregroundStyle(markerColor)
                .frame(width: 16)
            Text(verbatim: line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .noNewline ? .tertiary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.vertical, 1)
        .background(background)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var marker: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        default: " "
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .addition: AgentHomePalette.done
        case .deletion: .red
        default: .clear
        }
    }

    private var background: Color {
        switch line.kind {
        case .addition: AgentHomePalette.done.opacity(0.12)
        case .deletion: Color.red.opacity(0.10)
        default: .clear
        }
    }
}

/// A conversation on a line: its comments, open or resolved, outdated or not.
private struct AgentHomePRThreadCard: View {
    let thread: GitHubPullRequestDetail.ReviewThread
    let showsPath: Bool
    let onLink: (URL) -> Void

    @State private var isExpanded: Bool?

    var body: some View {
        let expanded = isExpanded ?? !thread.isResolved
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded = !expanded }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: thread.isResolved ? "checkmark.bubble" : "bubble.left")
                        .foregroundStyle(thread.isResolved ? AgentHomePalette.done : AgentHomePalette.running)
                    Text(thread.isResolved
                        ? String(localized: "agentHome.pr.thread.resolved", defaultValue: "Resolved · \(thread.comments.count)")
                        : String(localized: "agentHome.pr.thread.open", defaultValue: "Open · \(thread.comments.count)"))
                        .fontWeight(.medium)
                    if thread.isOutdated {
                        Text(String(localized: "agentHome.pr.thread.outdated", defaultValue: "outdated")).foregroundStyle(.tertiary)
                    }
                    if showsPath {
                        Text(thread.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                }
                .font(.system(size: 11.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                if showsPath, let hunk = thread.diffHunk {
                    let lines = GitHubDiffHunk.parse(hunk).flatMap(\.lines).suffix(4)
                    VStack(spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in AgentHomePRDiffLine(line: line) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                ForEach(thread.comments) { comment in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            if let author = comment.author { AgentHomeAvatar(actor: author, size: 16) }
                            Text(comment.author?.login ?? "ghost").font(.system(size: 11.5, weight: .semibold))
                            if let date = comment.createdAt { Text(AgentHomePRFormat.ago(date)).font(.system(size: 11)).foregroundStyle(.tertiary) }
                        }
                        AgentHomeHTMLBlock(html: comment.bodyHTML, onLink: onLink)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}
