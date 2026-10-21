import AppKit
import Charts
import CmuxAgentHome
import SwiftUI

// MARK: - Colours and formatting

/// Account colours: a fixed categorical order assigned by T3's account order,
/// so an account keeps its colour whatever it spends. Spend no account claims is grey.
enum AgentHomeUsageColors {
    private static let categorical: [(light: UInt32, dark: UInt32)] = [
        (0x2A78D6, 0x3987E5), // blue
        (0xEB6834, 0xD95926), // orange
        (0x1BAF7A, 0x199E70), // aqua
        (0xEDA100, 0xC98500), // yellow
        (0xE87BA4, 0xD55181), // magenta
        (0x008300, 0x008300), // green
        (0x6250D6, 0x9085E9), // violet
        (0xE34948, 0xE66767), // red
    ]

    static func color(forSpender id: String, in report: ProviderUsageReport) -> Color {
        guard let index = report.limits.firstIndex(where: { $0.id == id }) else {
            return Color(nsColor: .tertiaryLabelColor)
        }
        let pair = categorical[index % categorical.count]
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = dark ? pair.dark : pair.light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

enum AgentHomeUsageFormat {
    static func cost(_ usd: Double) -> String {
        usd.formatted(.currency(code: "USD").precision(.fractionLength(usd >= 1000 ? 0 : 2)))
    }

    static func axisCost(_ usd: Double) -> String {
        usd.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }

    /// Token counts in thousands, millions and billions (688B, 44.6M), as T3 shows them,
    /// whatever the region's own grouping (an Indian region would otherwise say 688Cr).
    static func tokens(_ count: Int) -> String {
        count.formatted(
            .number.notation(.compactName).precision(.significantDigits(1...3)).locale(Locale(identifier: "en_US"))
        )
    }

    static func resetsIn(_ interval: TimeInterval) -> String {
        if interval < 60 { return String(localized: "agentHome.usage.resetsNow", defaultValue: "Resets now") }
        let days = Int(interval) / 86_400
        let hours = Int(interval) % 86_400 / 3600
        let minutes = Int(interval) % 3600 / 60
        let span = days > 0 ? "\(days)d \(hours)h" : hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
        return String(localized: "agentHome.usage.resetsIn", defaultValue: "Resets in \(span)")
    }

    static func paceTitle(_ pace: ProviderUsageWindow.Pace) -> String {
        switch pace {
        case .ahead: return String(localized: "agentHome.usage.pace.ahead", defaultValue: "Ahead of pace")
        case .on: return String(localized: "agentHome.usage.pace.on", defaultValue: "On pace")
        case .under: return String(localized: "agentHome.usage.pace.under", defaultValue: "Under pace")
        }
    }

    static func paceIcon(_ pace: ProviderUsageWindow.Pace) -> String {
        switch pace {
        case .ahead: return "chart.line.uptrend.xyaxis"
        case .on: return "gauge.with.dots.needle.50percent"
        case .under: return "chart.line.downtrend.xyaxis"
        }
    }
}
