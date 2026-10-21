import AppKit
import CmuxAgentHome
import SwiftUI

// MARK: - Shared pieces

struct AgentHomePRStateStyle {
    let detail: GitHubPullRequestDetail

    var color: Color {
        switch detail.state {
        case .merged: AgentHomeT3PullRequestStateGlyph.merged
        case .closed: AgentHomePalette.danger
        case .open: detail.isDraft ? Color(nsColor: .systemGray) : AgentHomePalette.done
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

struct AgentHomePRStateBadge: View {
    let detail: GitHubPullRequestDetail

    var body: some View {
        let style = AgentHomePRStateStyle(detail: detail)
        HStack(spacing: 4) {
            Image(systemName: style.symbol).font(.system(size: 10, weight: .semibold))
            Text(style.label).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(AgentHomePalette.onFill)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(style.color))
    }
}

struct AgentHomePRButton: View {
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
            .foregroundStyle(AgentHomePalette.onFill)
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

struct AgentHomePRReviewerChip: View {
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

struct AgentHomePRVerdictLabel: View {
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

struct AgentHomePRLabelChip: View {
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
