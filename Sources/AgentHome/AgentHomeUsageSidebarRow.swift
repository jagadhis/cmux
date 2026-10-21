import AppKit
import Charts
import CmuxAgentHome
import SwiftUI

// MARK: - Sidebar row

/// The sidebar's Usage row: opens the Usage page, with a small meter for the
/// window closest to running out.
struct AgentHomeUsageSidebarRow: View {
    let isSelected: Bool
    let report: ProviderUsageReport?
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 9) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(String(localized: "agentHome.usage.title", defaultValue: "Usage"))
                    .font(.system(size: 13))
                Spacer(minLength: 4)
                if let report, let tightest = report.tightestWindow(now: Date()) {
                    let remaining = tightest.window.remainingPercent(now: Date())
                    let status = AgentHomeUsageStatus(remainingPercent: remaining)
                    if let status {
                        Image(systemName: status.icon)
                            .font(.system(size: 9.5))
                            .foregroundStyle(status.color)
                    }
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        Capsule()
                            .fill(status?.color ?? AgentHomeUsageColors.color(forSpender: tightest.account.id, in: report))
                            .frame(width: max(2, 34 * CGFloat(remaining) / 100))
                    }
                    .frame(width: 34, height: 4)
                    Text("\(remaining)%")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .agentHomeRowBackground(isSelected: isSelected, isHovered: isHovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
        .help(helpText)
    }

    private var helpText: String {
        guard let tightest = report?.tightestWindow(now: Date()) else {
            return String(localized: "agentHome.usage.sidebarHelp", defaultValue: "Provider limits and spend")
        }
        return String(
            localized: "agentHome.usage.sidebarHelpTightest",
            defaultValue: "Closest to its limit: \(tightest.account.name), \(tightest.window.label), \(tightest.window.remainingPercent(now: Date()))% left"
        )
    }
}
