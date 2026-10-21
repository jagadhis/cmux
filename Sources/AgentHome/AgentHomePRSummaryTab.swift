import AppKit
import CmuxAgentHome
import SwiftUI

// MARK: - Summary

struct AgentHomePRSummaryTab: View {
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

struct AgentHomePRSection<Content: View>: View {
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

struct AgentHomePRCheckRow: View {
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
struct AgentHomePRChecksLine: View {
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

struct AgentHomePRCheckIcon: View {
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

struct AgentHomePRCommentCard: View {
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
                    Text(AgentHomeFormat.relative(date)).font(.system(size: 11.5)).foregroundStyle(.tertiary)
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
