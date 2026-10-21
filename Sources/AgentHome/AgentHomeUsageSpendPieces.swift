import AppKit
import Charts
import CmuxAgentHome
import SwiftUI

// MARK: - Spend pieces

struct AgentHomeUsageStatTile: View {
    let title: String
    let value: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail ?? " ")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
    }
}

/// A ranked list with each row's share of the total as a thin bar.
struct AgentHomeUsageBreakdown: View {
    struct Row: Identifiable {
        let id: String
        let label: String
        let detail: String
        let costUsd: Double
        let color: Color?
    }

    let title: String
    let rows: [Row]
    let total: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(rows) { row in
                let share = total > 0 ? row.costUsd / total : 0
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if let color = row.color {
                            Circle().fill(color).frame(width: 7, height: 7)
                        }
                        Text(row.label)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(row.detail)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Text(AgentHomeUsageFormat.cost(row.costUsd))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .frame(minWidth: 64, alignment: .trailing)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.06))
                            Capsule()
                                .fill(row.color ?? Color.primary.opacity(0.35))
                                .frame(width: max(3, proxy.size.width * share))
                        }
                    }
                    .frame(height: 3)
                }
                .help(String(localized: "agentHome.usage.share", defaultValue: "\(Int((share * 100).rounded()))% of the period's cost"))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
    }
}

/// Explains why spend is hidden and how to show it.
struct AgentHomeUsageScopeCard: View {
    let onCopy: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "agentHome.usage.scope.title", defaultValue: "Spend needs one more permission"), systemImage: "lock")
                .font(.system(size: 12.5, weight: .semibold))
            Text(String(
                localized: "agentHome.usage.scope.body",
                defaultValue: "T3 only shares token use and cost with tokens that have the diagnostics:read scope. Run this in a terminal to replace cmux's T3 token with one that has it. Spend shows up on the next refresh."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 8) {
                Text(AgentHomeUsageModel.diagnosticsScopeCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                Button {
                    onCopy()
                    copied = true
                } label: {
                    Label(
                        copied
                            ? String(localized: "agentHome.usage.scope.copied", defaultValue: "Copied")
                            : String(localized: "agentHome.usage.scope.copy", defaultValue: "Copy"),
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
    }
}

struct AgentHomeUsageSectionTitle: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 11.5)).foregroundStyle(.tertiary)
        }
    }
}

struct AgentHomeUsageNote: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
    }
}
