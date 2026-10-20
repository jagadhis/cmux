import CmuxAgentHome
import SwiftUI

/// A T3 Code task that isn't open in cmux yet. Clicking opens it as a cmux task.
struct AgentHomeT3TaskRow: View {
    let proposal: T3TaskProposal
    let indented: Bool
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Text(proposal.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                if isHovered {
                    Text(String(localized: "agentHome.t3.open", defaultValue: "Open"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                } else if proposal.threads.count > 1 {
                    Text(proposal.threads.count, format: .number)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                AgentHomeT3Tag()
            }
            .padding(.leading, indented ? 24 : 0)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
        .help(helpText)
    }

    private var helpText: String {
        let threads = proposal.threads.count == 1
            ? String(localized: "agentHome.t3.oneThread", defaultValue: "1 T3 thread")
            : String(localized: "agentHome.t3.threads", defaultValue: "\(proposal.threads.count) T3 threads")
        return threads + " · " + proposal.branch
    }
}

/// "N more from T3" under a project, toggling the rest of its T3 tasks.
struct AgentHomeT3MoreRow: View {
    let hiddenCount: Int
    let isExpanded: Bool
    let indented: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                Text(isExpanded
                    ? String(localized: "agentHome.t3.showLess", defaultValue: "Show less")
                    : String(localized: "agentHome.t3.more", defaultValue: "\(hiddenCount) more from T3"))
                Spacer()
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
            .padding(.leading, indented ? 33 : 9)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A T3 project that has no cmux project yet.
struct AgentHomeT3ProjectRow: View {
    let name: String
    let taskCount: Int
    let isCollapsed: Bool
    let onToggleCollapsed: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onToggleCollapsed) {
                HStack(spacing: 9) {
                    AgentHomeProjectBadge(name: name, colorHex: nil)
                        .opacity(0.55)
                    Text(name)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(taskCount, format: .number)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            AgentHomeDisclosureChevron(isCollapsed: isCollapsed, action: onToggleCollapsed)
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
    }
}

/// Threads T3 couldn't place in a task: on a default branch or without a project.
struct AgentHomeT3UnsortedRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "tray")
                .font(.system(size: 12))
                .frame(width: 16)
            Text(String(localized: "agentHome.t3.unsorted", defaultValue: "Unsorted T3 threads"))
                .font(.system(size: 13))
            Spacer(minLength: 4)
            Text(count, format: .number)
                .font(.system(size: 11.5).monospacedDigit())
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .help(String(localized: "agentHome.t3.unsortedHelp", defaultValue: "T3 threads on a default branch or without a project. Sorting them into tasks comes next."))
    }
}

private struct AgentHomeT3Tag: View {
    var body: some View {
        Text(verbatim: "T3")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3.5).fill(Color.primary.opacity(0.08)))
    }
}
