import AppKit
import CmuxAgentHome
import SwiftUI

// MARK: - Timeline

struct AgentHomePRTimelineTab: View {
    let detail: GitHubPullRequestDetail
    let newestFirst: Bool
    let onLink: (URL) -> Void
    let onShowCode: () -> Void

    @State private var expandedRuns: Set<String> = []

    var body: some View {
        // Lazy: every comment is a web view, so only the ones near the screen exist.
        LazyVStack(alignment: .leading, spacing: 10) {
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
                    if let date = commit.date { Text(AgentHomeFormat.relative(date)).font(.system(size: 11.5)).foregroundStyle(.tertiary) }
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
                        if let date = run.last?.createdAt { Text(AgentHomeFormat.relative(date)).font(.system(size: 11.5)).foregroundStyle(.tertiary) }
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
                    if let date = review.createdAt { Text(AgentHomeFormat.relative(date)).font(.system(size: 11.5)).foregroundStyle(.tertiary) }
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
            if let date { Text(AgentHomeFormat.relative(date)).font(.system(size: 11.5)).foregroundStyle(.tertiary) }
        }
    }
}
