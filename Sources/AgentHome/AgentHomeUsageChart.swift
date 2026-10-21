import AppKit
import Charts
import CmuxAgentHome
import SwiftUI

/// Cost per day (or hour), stacked by account, with a tooltip for the hovered bar.
struct AgentHomeUsageChart: View {
    let digest: ProviderUsageDigest
    let report: ProviderUsageReport
    let hourly: Bool

    /// The slot under the pointer; changes only when the pointer crosses into another bar.
    @State private var selectedSlot: Date?

    private struct Bar: Identifiable {
        var id: String { "\(slot.timeIntervalSince1970)-\(spenderId)" }
        let slot: Date
        let spenderId: String
        let label: String
        let costUsd: Double
    }

    var body: some View {
        let bars = bars()
        let labels = digest.spenders.map(\.label)
        let colors = digest.spenders.map { AgentHomeUsageColors.color(forSpender: $0.id, in: report) }
        let slots = Set(bars.map(\.slot))
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach(bars) { bar in
                    BarMark(
                        x: .value("Time", bar.slot, unit: hourly ? .hour : .day),
                        y: .value("Cost", bar.costUsd)
                    )
                    .foregroundStyle(by: .value("Account", bar.label))
                    .cornerRadius(2)
                    .opacity(selectedSlot == nil || selectedSlot == bar.slot ? 1 : 0.45)
                }
                if let selectedSlot {
                    RuleMark(x: .value("Time", selectedSlot, unit: hourly ? .hour : .day))
                        .foregroundStyle(Color.primary.opacity(0.12))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            tooltip(slot: selectedSlot, bars: bars.filter { $0.slot == selectedSlot })
                        }
                }
            }
            .chartForegroundStyleScale(domain: labels, range: colors)
            .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let originX = proxy.plotFrame.map { geometry[$0].origin.x } ?? 0
                                let slot = proxy.value(atX: location.x - originX, as: Date.self).flatMap { slot(at: $0, in: slots) }
                                if slot != selectedSlot { selectedSlot = slot }
                            case .ended:
                                if selectedSlot != nil { selectedSlot = nil }
                            }
                        }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                    AxisValueLabel {
                        if let cost = value.as(Double.self) { Text(AgentHomeUsageFormat.axisCost(cost)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: hourly ? 6 : 7)) { _ in
                    AxisValueLabel(format: hourly ? .dateTime.hour() : .dateTime.month(.abbreviated).day(), centered: true)
                }
            }
            .frame(height: 210)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
    }

    private func tooltip(slot: Date, bars: [Bar]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hourly ? slot.formatted(date: .abbreviated, time: .shortened) : slot.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 11, weight: .semibold))
            ForEach(bars.sorted { $0.costUsd > $1.costUsd }) { bar in
                HStack(spacing: 6) {
                    Circle()
                        .fill(AgentHomeUsageColors.color(forSpender: bar.spenderId, in: report))
                        .frame(width: 6, height: 6)
                    Text(bar.label).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 10)
                    Text(AgentHomeUsageFormat.cost(bar.costUsd)).font(.system(size: 11).monospacedDigit())
                }
            }
            if bars.count > 1 {
                Divider()
                HStack {
                    Text(String(localized: "agentHome.usage.total", defaultValue: "Total")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 10)
                    Text(AgentHomeUsageFormat.cost(bars.reduce(0) { $0 + $1.costUsd }))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
            }
        }
        .padding(8)
        .frame(minWidth: 170)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }

    /// The bar under a point in time: the latest slot starting at or before it.
    private func slot(at date: Date, in slots: Set<Date>) -> Date? {
        slots.filter { $0 <= date && date.timeIntervalSince($0) < (hourly ? 3600 : 86_400) }.max()
    }

    private func bars() -> [Bar] {
        let labels = Dictionary(uniqueKeysWithValues: digest.spenders.map { ($0.id, $0.label) })
        return digest.points.compactMap { point in
            guard let slot = point.slotStart else { return nil }
            return Bar(slot: slot, spenderId: point.spenderId, label: labels[point.spenderId] ?? point.spenderId, costUsd: point.costUsd)
        }
    }
}
