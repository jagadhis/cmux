import CmuxAgentHome
import SwiftUI

/// A T3 Code task: a thread the user started. Shows how many sub-threads its
/// agents created and its most urgent status.
struct AgentHomeT3TaskRow: View {
    let task: T3TaskNode
    let isSelected: Bool
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Text(task.thread.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Spacer(minLength: 4)
                if !task.subThreads.isEmpty {
                    Text(task.subThreads.count, format: .number)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .help(String(localized: "agentHome.t3.subThreads", defaultValue: "\(task.subThreads.count) sub-threads"))
                }
                AgentHomeT3StatusDot(status: task.status)
            }
            .padding(.leading, 24)
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
        .accessibilityLabel(Text(task.thread.title))
    }
}

/// A sub-thread an agent created, nested under its task.
struct AgentHomeT3SubThreadRow: View {
    let thread: T3Thread
    let isSelected: Bool
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Text(verbatim: "↳")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(thread.title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Spacer(minLength: 4)
                AgentHomeT3StatusDot(status: T3ThreadStatus.of(thread), showsDone: true)
            }
            .padding(.leading, 34)
            .padding(.horizontal, 9)
            .frame(height: 25)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.09 : (isHovered ? 0.05 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityLabel(Text(thread.title))
    }
}

/// "N more" under a project, toggling the rest of its T3 tasks.
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
                    : String(localized: "agentHome.t3.moreTasks", defaultValue: "\(hiddenCount) more"))
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

/// A T3 project that has no cmux project. Clicking folds it.
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
                    Text(name)
                        .font(.system(size: 13))
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

/// The status mark for a T3 task or sub-thread.
struct AgentHomeT3StatusDot: View {
    let status: T3ThreadStatus
    var showsDone = false

    var body: some View {
        switch status {
        case .needsYou:
            AgentHomeStatusDot(status: .needsYou)
        case .running:
            AgentHomeStatusDot(status: .running)
        case .idle:
            if showsDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)
            } else {
                Color.clear.frame(width: 14, height: 14)
            }
        }
    }
}

/// The "New chat" button at the top of the sidebar.
struct AgentHomeNewChatButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11.5, weight: .semibold))
                Text(String(localized: "agentHome.newChat", defaultValue: "New chat"))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.1 : 0.07))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(String(localized: "agentHome.newChat.help", defaultValue: "Start a new T3 thread in a project"))
    }
}
