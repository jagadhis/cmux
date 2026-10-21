import CmuxAgentHome
import SwiftUI

struct AgentHomeCheckBars: View {
    let checks: [AgentHomePullRequest.Check]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                Capsule()
                    .fill(check.outcome == .passed ? AgentHomePalette.done : check.outcome == .failed ? Color.red : AgentHomePalette.needsYou)
                    .frame(width: 10, height: 4)
            }
        }
    }
}

private struct AgentHomeCardModifier: ViewModifier {
    var highlight: Color?
    var hovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(hovered ? 0.05 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(highlight?.opacity(0.4) ?? Color.primary.opacity(0.07), lineWidth: 0.5)
            )
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(highlight?.opacity(0.06) ?? .clear)
                    .padding(-3)
            )
    }
}

extension View {
    func agentHomeCard(highlight: Color? = nil, hovered: Bool = false) -> some View {
        modifier(AgentHomeCardModifier(highlight: highlight, hovered: hovered))
    }
}
