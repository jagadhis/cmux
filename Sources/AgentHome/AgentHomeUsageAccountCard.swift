import AppKit
import Charts
import CmuxAgentHome
import SwiftUI

// MARK: - Account card

/// One account: its name and plan, then a bar per window showing what's left,
/// with a tick where even spending would be and the time to reset.
struct AgentHomeUsageAccountCard: View {
    let account: ProviderAccountLimits
    let color: Color
    let isMostHeadroom: Bool
    let spend: ProviderUsageDigest.Spender?
    let periodTitle: String
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if isMostHeadroom {
                            Label(String(localized: "agentHome.usage.mostHeadroom", defaultValue: "Most room"), systemImage: "arrow.up.forward")
                                .labelStyle(.titleAndIcon)
                                .fixedSize()
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(AgentHomePalette.done)
                                .padding(.horizontal, 6)
                                .frame(height: 17)
                                .background(Capsule().fill(AgentHomePalette.done.opacity(0.13)))
                                .help(String(localized: "agentHome.usage.mostHeadroomHelp", defaultValue: "The most room left in its tightest window: a good pick for the next long run"))
                        }
                    }
                    Text([account.email, account.plan].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if let spend {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(AgentHomeUsageFormat.cost(spend.costUsd))
                            .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                        Text(periodTitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            VStack(spacing: 11) {
                ForEach(account.windows) { window in
                    AgentHomeUsageWindowRow(window: window, color: color, now: now)
                }
            }
            if account.unavailableReason == "probeFailed" {
                Label(account.unavailableMessage ?? String(localized: "agentHome.usage.probeFailed", defaultValue: "The last check failed; showing the previous one."), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let checked = account.checkedAt {
                Text(String(localized: "agentHome.usage.checked", defaultValue: "Checked \(AgentHomeFormat.relative(checked, now: now))"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isMostHeadroom ? AgentHomePalette.done.opacity(0.45) : Color.primary.opacity(0.07))
        )
    }
}

/// A window's label and percent left over its bar, with pace and reset time underneath.
struct AgentHomeUsageWindowRow: View {
    let window: ProviderUsageWindow
    let color: Color
    let now: Date

    var body: some View {
        let hasReset = window.hasReset(now: now)
        let remaining = window.remainingPercent(now: now)
        let elapsed = hasReset ? nil : window.elapsedShare(now: now)
        let status = AgentHomeUsageStatus(remainingPercent: remaining)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(window.label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let status {
                    Label(status.title, systemImage: status.icon)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(status.color)
                }
                Spacer(minLength: 4)
                Text(String(localized: "agentHome.usage.left", defaultValue: "\(remaining)% left"))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if remaining > 0 {
                        Capsule()
                            .fill(color)
                            .frame(width: max(6, width * CGFloat(remaining) / 100))
                    }
                    if let elapsed {
                        // Where the bar would be with even spending: the share of the window still to come.
                        Rectangle()
                            .fill(Color.primary.opacity(0.55))
                            .frame(width: 1.5, height: 12)
                            .offset(x: width * CGFloat(1 - elapsed) - 0.75)
                    }
                }
                .frame(height: 6)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 12)
            .help(helpText(remaining: remaining, elapsed: elapsed))
            HStack(spacing: 6) {
                if let pace = window.pace(now: now) {
                    Label(AgentHomeUsageFormat.paceTitle(pace), systemImage: AgentHomeUsageFormat.paceIcon(pace))
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 10.5))
                        .foregroundStyle(pace == .ahead ? AnyShapeStyle(AgentHomePalette.needsYou) : AnyShapeStyle(.tertiary))
                }
                Spacer(minLength: 4)
                if hasReset {
                    Text(String(localized: "agentHome.usage.resetSinceCheck", defaultValue: "Reset since T3's last check"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                } else if let resetIn = window.timeUntilReset(now: now) {
                    Text(AgentHomeUsageFormat.resetsIn(resetIn))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .help(window.resetsAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                }
            }
        }
    }

    private func helpText(remaining: Int, elapsed: Double?) -> String {
        guard let elapsed else {
            return String(localized: "agentHome.usage.help.left", defaultValue: "\(window.label): \(remaining)% left")
        }
        let timeLeft = Int(((1 - elapsed) * 100).rounded())
        return String(
            localized: "agentHome.usage.help.leftWithTime",
            defaultValue: "\(window.label): \(remaining)% left, \(timeLeft)% of the window to go. The tick is where even spending would be."
        )
    }
}

/// How close a window is to running out, shown with an icon and a word, never colour alone.
struct AgentHomeUsageStatus {
    let title: String
    let icon: String
    let color: Color

    init?(remainingPercent: Int) {
        if remainingPercent <= 10 {
            title = String(localized: "agentHome.usage.status.critical", defaultValue: "Almost out")
            icon = "exclamationmark.octagon.fill"
            color = AgentHomePalette.danger
        } else if remainingPercent <= 25 {
            title = String(localized: "agentHome.usage.status.low", defaultValue: "Low")
            icon = "exclamationmark.triangle.fill"
            color = AgentHomePalette.needsYou
        } else {
            return nil
        }
    }
}
