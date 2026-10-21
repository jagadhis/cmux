import CMUXAgentLaunch
import CmuxAgentHome
import SwiftUI

struct AgentHomeAgentCard: View {
    let agent: AgentHomeAgent
    let onReply: (AgentHomePermissionRequest, WorkstreamPermissionMode) -> Void
    let onOpenTerminal: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AgentHomeAgentAvatar(kind: agent.kind, contextFraction: agent.contextFraction)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if isHovered {
                    Button(action: onOpenTerminal) {
                        Image(systemName: "terminal").font(.system(size: 11.5))
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "agentHome.card.openTerminal", defaultValue: "Open this agent's terminal"))
                    .transition(.opacity)
                }
                AgentHomeStatePill(state: agent.state)
            }

            Group {
                if agent.state == .running, let activity = agent.currentActivity {
                    AgentHomeShimmerText(text: activity + "…")
                        .id(activity)
                        .transition(.opacity.combined(with: .offset(y: 3)))
                } else if agent.state == .needsYou, agent.pendingPermission == nil {
                    Text(String(localized: "agentHome.card.waiting", defaultValue: "Waiting for your answer in the terminal"))
                        .foregroundStyle(AgentHomePalette.needsYou)
                } else if agent.state == .idle, let summary = agent.lastSummary {
                    Text(summary).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .font(.system(size: 12.5))
            .padding(.leading, 40)
            .padding(.top, 9)
            .animation(.easeOut(duration: 0.3), value: agent.currentActivity)

            if agent.state != .idle, !agent.plan.isEmpty {
                AgentHomePlanList(steps: agent.plan, isWaiting: agent.state == .needsYou)
                    .padding(.leading, 40)
                    .padding(.top, 9)
            }

            if let request = agent.pendingPermission {
                AgentHomeApprovalRow(request: request, onReply: onReply)
                    .padding(.leading, 40)
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .agentHomeCard(highlight: agent.state == .needsYou ? AgentHomePalette.needsYou : nil, hovered: isHovered)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
        .onTapGesture(count: 2, perform: onOpenTerminal)
        .animation(.spring(duration: 0.35), value: agent.state)
        .animation(.spring(duration: 0.35), value: agent.pendingPermission)
    }

    private var subtitle: String {
        var parts = [agent.kind.displayName + (agent.modelName.map { " " + $0 } ?? "")]
        if agent.state == .idle, let last = agent.lastActivityAt {
            parts.append(AgentHomeFormat.relative(last))
        } else if let startedAt = agent.startedAt {
            parts.append(AgentHomeFormat.elapsed(since: startedAt))
        }
        if agent.state != .idle, let fraction = agent.contextFraction {
            parts.append(String(localized: "agentHome.card.context", defaultValue: "\(Int((fraction * 100).rounded()))% context"))
        }
        return parts.joined(separator: " · ")
    }
}

struct AgentHomeAgentAvatar: View {
    let kind: AgentHomeAgentKind
    let contextFraction: Double?

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 2)
            if let contextFraction {
                Circle()
                    .trim(from: 0, to: contextFraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Circle().fill(color.opacity(0.16)).frame(width: 22, height: 22)
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(width: 30, height: 30)
        .help(contextFraction.map {
            String(localized: "agentHome.card.contextHelp", defaultValue: "\(Int(($0 * 100).rounded()))% of the context window used")
        } ?? "")
    }

    private var symbol: String {
        switch kind {
        case .claude: return "asterisk"
        case .codex: return "hexagon"
        case .opencode: return "square"
        case .other: return "terminal"
        }
    }

    private var color: Color {
        switch kind {
        case .claude: return AgentHomePalette.adaptive(light: 0xB75B38, dark: 0xD97857)
        case .codex: return Color.primary.opacity(0.85)
        case .opencode: return AgentHomePalette.adaptive(light: 0x548C14, dark: 0x8CCC40)
        case .other: return Color.secondary
        }
    }
}

struct AgentHomeStatePill: View {
    let state: AgentHomeAgentState

    var body: some View {
        HStack(spacing: 5) {
            if state == .running { AgentHomeActivityBars() }
            Text(title)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(color.opacity(0.13)))
    }

    private var title: String {
        switch state {
        case .needsYou: return String(localized: "agentHome.state.needsYou", defaultValue: "Needs you")
        case .running: return String(localized: "agentHome.state.working", defaultValue: "Working")
        case .idle: return String(localized: "agentHome.state.idle", defaultValue: "Idle")
        }
    }

    private var color: Color {
        switch state {
        case .needsYou: return AgentHomePalette.needsYou
        case .running: return AgentHomePalette.running
        case .idle: return .secondary
        }
    }
}

private struct AgentHomePlanList: View {
    let steps: [AgentHomePlanStep]
    let isWaiting: Bool

    var body: some View {
        let currentIndex = steps.firstIndex { $0.status != .completed }
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 8) {
                    AgentHomeStepMark(
                        status: step.status,
                        isCurrent: index == currentIndex,
                        isWaiting: isWaiting
                    )
                    Text(step.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(index == currentIndex ? .primary : .secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct AgentHomeStepMark: View {
    let status: AgentHomePlanStep.Status
    let isCurrent: Bool
    let isWaiting: Bool

    /// Seconds per turn of the current step's spinner.
    private static let turn: TimeInterval = 1.6

    var body: some View {
        ZStack {
            if status == .completed {
                Circle().fill(AgentHomePalette.done)
                Image(systemName: "checkmark").font(.system(size: 7.5, weight: .heavy)).foregroundStyle(AgentHomePalette.onFill)
            } else if isCurrent && isWaiting {
                Circle().strokeBorder(AgentHomePalette.needsYou, lineWidth: 1.3)
            } else if isCurrent {
                Circle().strokeBorder(AgentHomePalette.running.opacity(0.25), lineWidth: 1.5)
                AgentHomeMotionTimeline { time in
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(AgentHomePalette.running, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(360 * ((time ?? 0).truncatingRemainder(dividingBy: Self.turn) / Self.turn)))
                }
            } else {
                Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1.3)
            }
        }
        .frame(width: 14, height: 14)
    }
}

private struct AgentHomeApprovalRow: View {
    let request: AgentHomePermissionRequest
    let onReply: (AgentHomePermissionRequest, WorkstreamPermissionMode) -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Text(verbatim: "$").foregroundStyle(.tertiary)
                Text(request.summary).lineLimit(1).truncationMode(.tail)
            }
            .font(.system(size: 11.5, design: .monospaced))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
            .help(request.summary)

            Button(String(localized: "agentHome.approval.deny", defaultValue: "Deny")) { onReply(request, .deny) }
                .buttonStyle(AgentHomeButtonStyle())
            if request.canAlwaysAllow {
                Button(String(localized: "agentHome.approval.always", defaultValue: "Always allow")) { onReply(request, .always) }
                    .buttonStyle(AgentHomeButtonStyle())
            }
            Button(String(localized: "agentHome.approval.allow", defaultValue: "Allow")) { onReply(request, .once) }
                .buttonStyle(AgentHomeButtonStyle(isPrimary: true))
        }
    }
}

/// Text with a light sweeping across it, for an agent's live activity.
private struct AgentHomeShimmerText: View {
    let text: String

    /// Seconds per sweep.
    private static let sweep: TimeInterval = 2.2

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .overlay {
                AgentHomeMotionTimeline { time in
                    if let time {
                        // -1 → 1 across each sweep: the highlight's position along the text.
                        let phase = 2 * time.truncatingRemainder(dividingBy: Self.sweep) / Self.sweep - 1
                        GeometryReader { proxy in
                            LinearGradient(
                                colors: [.clear, Color.primary.opacity(0.55), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: proxy.size.width * 0.45)
                            .offset(x: phase * proxy.size.width * 1.4)
                        }
                        .mask(Text(text))
                    }
                }
                .allowsHitTesting(false)
            }
    }
}

private struct AgentHomeButtonStyle: ButtonStyle {
    var isPrimary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isPrimary ? Color.primary.opacity(configuration.isPressed ? 0.8 : 0.92) : Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08))
            )
            .foregroundStyle(isPrimary ? Color(nsColor: .windowBackgroundColor) : Color.primary)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
