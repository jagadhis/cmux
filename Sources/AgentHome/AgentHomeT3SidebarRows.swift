import CmuxAgentHome
import SwiftUI

/// A T3 Code task: a thread the user started. Shows how many sub-threads its
/// agents created and its most urgent status. A finished task reads brighter
/// until the user has looked at it, and offers Verify on hover.
struct AgentHomeT3TaskRow: View {
    let task: T3TaskNode
    let isSelected: Bool
    let onOpen: () -> Void
    let onVerify: () -> Void

    @State private var isHovered = false

    var body: some View {
        let status = task.status
        let unseen = task.hasUnseenResult
        HStack(spacing: 8) {
            Text(task.thread.title)
                .font(.system(size: 13, weight: unseen ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isSelected || unseen ? .primary : .secondary)
            Spacer(minLength: 4)
            if status == .done && (isHovered || isSelected) {
                AgentHomeT3VerifyButton(compact: true, action: onVerify)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            } else {
                if !task.subThreads.isEmpty {
                    Text(task.subThreads.count, format: .number)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .help(String(localized: "agentHome.t3.subThreads", defaultValue: "\(task.subThreads.count) sub-threads"))
                }
                AgentHomeT3StatusDot(status: status, unseen: unseen, endedEarly: task.thread.latestRunEndedEarly)
            }
        }
        .padding(.leading, 24)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.09 : (isHovered ? 0.05 : 0)))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(task.thread.title))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(String(localized: "agentHome.t3.verify", defaultValue: "Mark verified"))) {
            if status == .done { onVerify() }
        }
    }
}

/// "Mark verified": settles a finished task in T3 once the user has checked its result.
struct AgentHomeT3VerifyButton: View {
    var compact = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: compact ? 9 : 10, weight: .bold))
                if !compact {
                    Text(String(localized: "agentHome.t3.verify", defaultValue: "Mark verified"))
                        .font(.system(size: 11.5, weight: .semibold))
                }
            }
            .foregroundStyle(compact && !isHovered ? AgentHomePalette.done : .white)
            .padding(.horizontal, compact ? 5 : 10)
            .frame(height: compact ? 18 : 24)
            .background(
                Capsule().fill(compact && !isHovered ? AgentHomePalette.done.opacity(0.16) : AgentHomePalette.done)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
        .help(String(localized: "agentHome.t3.verify.help", defaultValue: "You've checked the result: settle it in T3 and move on"))
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

/// The status mark for a T3 task or sub-thread: amber for needs you, a pulse
/// while working, and a green check when done (filled until the user has
/// looked). A run that stopped early shows an amber mark instead.
struct AgentHomeT3StatusDot: View {
    let status: T3ThreadStatus
    var showsDone = false
    var unseen = false
    var endedEarly = false

    var body: some View {
        switch status {
        case .needsYou:
            AgentHomeStatusDot(status: .needsYou)
        case .running:
            AgentHomeStatusDot(status: .running)
        case .done:
            let color = endedEarly ? AgentHomePalette.needsYou : AgentHomePalette.done
            ZStack {
                if unseen {
                    Circle().fill(color).frame(width: 12, height: 12)
                    Image(systemName: endedEarly ? "exclamationmark" : "checkmark")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(.white)
                } else {
                    Circle().strokeBorder(color.opacity(0.85), lineWidth: 1.2).frame(width: 12, height: 12)
                    Image(systemName: endedEarly ? "exclamationmark" : "checkmark")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(color)
                }
            }
            .frame(width: 14, height: 14)
            .help(endedEarly
                ? String(localized: "agentHome.t3.stopped", defaultValue: "Stopped before finishing. Check it, then mark it verified")
                : String(localized: "agentHome.t3.doneHelp", defaultValue: "Done. Check the result, then mark it verified"))
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

/// The task's state in its header: Working, Needs you, Done with Mark verified, or Verified.
struct AgentHomeT3StatusBar: View {
    let task: T3TaskNode
    let onVerify: () -> Void

    var body: some View {
        switch task.status {
        case .needsYou:
            pill(String(localized: "agentHome.state.needsYou", defaultValue: "Needs you"), color: AgentHomePalette.needsYou) {
                Circle().fill(AgentHomePalette.needsYou).frame(width: 6, height: 6)
            }
        case .running:
            pill(String(localized: "agentHome.state.working", defaultValue: "Working"), color: AgentHomePalette.running) {
                AgentHomeActivityBars()
            }
        case .done:
            HStack(spacing: 8) {
                let endedEarly = task.thread.latestRunEndedEarly
                pill(
                    endedEarly
                        ? String(localized: "agentHome.state.stopped", defaultValue: "Stopped")
                        : String(localized: "agentHome.state.done", defaultValue: "Done"),
                    color: endedEarly ? AgentHomePalette.needsYou : AgentHomePalette.done
                ) {
                    Image(systemName: endedEarly ? "exclamationmark.circle.fill" : "checkmark.circle.fill").font(.system(size: 10))
                }
                AgentHomeT3VerifyButton(action: onVerify)
            }
            .transition(.opacity)
        case .idle:
            if task.thread.isSettled {
                pill(String(localized: "agentHome.state.verified", defaultValue: "Verified"), color: .secondary) {
                    Image(systemName: "checkmark.seal").font(.system(size: 10))
                }
            } else {
                pill(String(localized: "agentHome.t3.synced", defaultValue: "Synced with T3"), color: .secondary) {
                    Circle().fill(AgentHomePalette.done).frame(width: 6, height: 6)
                }
            }
        }
    }

    private func pill<Icon: View>(_ title: String, color: Color, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 5) {
            icon()
            Text(title)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// "Verified … Undo", or why a T3 change failed, at the bottom of the sidebar.
struct AgentHomeT3Toast: View {
    let verified: T3TaskNode?
    let error: String?
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(error == nil ? AgentHomePalette.done : AgentHomePalette.needsYou)
            Text(error ?? String(localized: "agentHome.t3.verifiedToast", defaultValue: "Verified · \(verified?.thread.title ?? "")"))
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if error == nil {
                Button(String(localized: "agentHome.t3.undo", defaultValue: "Undo"), action: onUndo)
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .foregroundStyle(AgentHomePalette.running)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        )
        .onTapGesture(perform: onDismiss)
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
