import Charts
import CmuxAgentHome
import SwiftUI

/// Provider usage across every signed-in account: how much of each rate-limit
/// window is left and whether spending is ahead of the window, then what the
/// agents spent over a period, by account and by model.
struct AgentHomeUsageView: View {
    @ObservedObject var tabManager: TabManager

    @Bindable private var model = AgentHomeUsageModel.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 26) {
                    if let report = model.report {
                        // Re-render every 30 s so reset countdowns and pace stay current between reads.
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            limitsSection(report, now: context.date)
                        }
                        spendSection(report)
                    } else if let error = model.errorMessage {
                        AgentHomeUsageNote(icon: "exclamationmark.triangle", text: error)
                    } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 60)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        }
        .background(.background)
        .onAppear {
            model.startIfNeeded(tabManager: tabManager)
            Task { await model.refresh() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text(String(localized: "agentHome.usage.title", defaultValue: "Usage"))
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            if let error = model.errorMessage, model.report != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(AgentHomePalette.needsYou)
                    .help(error)
            }
            if let updated = model.lastUpdated {
                Text(Date().timeIntervalSince(updated) < 60
                    ? String(localized: "agentHome.usage.updatedNow", defaultValue: "Updated just now")
                    : String(localized: "agentHome.usage.updated", defaultValue: "Updated \(AgentHomeFormat.relative(updated))"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(model.isLoading ? 360 : 0))
                    .animation(model.isLoading ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: model.isLoading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(String(localized: "agentHome.usage.refresh", defaultValue: "Refresh"))
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 22)
        .frame(height: 48)
    }

    // MARK: - Limits

    @ViewBuilder
    private func limitsSection(_ report: ProviderUsageReport, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentHomeUsageSectionTitle(
                title: String(localized: "agentHome.usage.limits", defaultValue: "Limits"),
                detail: String(localized: "agentHome.usage.limitsDetail", defaultValue: "What's left in each window, and where even spending would be")
            )
            let accounts = report.accountsWithWindows
            if accounts.isEmpty {
                AgentHomeUsageNote(icon: "gauge.with.dots.needle.0percent", text: String(
                    localized: "agentHome.usage.noLimits",
                    defaultValue: "None of your T3 providers report plan limits. Subscriptions such as Claude and ChatGPT do; API keys don't."
                ))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(accounts) { account in
                        AgentHomeUsageAccountCard(
                            account: account,
                            color: AgentHomeUsageColors.color(forSpender: account.id, in: report),
                            isMostHeadroom: report.mostHeadroomAccountId(now: now) == account.id,
                            spend: model.reportPeriod == model.period
                                ? model.digest?.spenders.first { $0.id == account.id }
                                : nil,
                            periodTitle: model.period.title,
                            now: now
                        )
                    }
                }
            }
            let withoutWindows = report.accountsWithoutWindows
            if !withoutWindows.isEmpty {
                Text(String(
                    localized: "agentHome.usage.noWindows",
                    defaultValue: "\(withoutWindows.map(\.name).formatted(.list(type: .and))) don't report plan limits (API key or unsupported)."
                ))
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Spend

    @ViewBuilder
    private func spendSection(_ report: ProviderUsageReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                AgentHomeUsageSectionTitle(
                    title: String(localized: "agentHome.usage.spend", defaultValue: "Spend"),
                    detail: String(localized: "agentHome.usage.spendDetail", defaultValue: "Priced from the agents' own transcripts at API rates")
                )
                Spacer(minLength: 12)
                Picker("", selection: $model.period) {
                    ForEach(AgentHomeUsageModel.Period.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if report.needsDiagnosticsScope {
                AgentHomeUsageScopeCard { model.copyDiagnosticsScopeCommand() }
            } else if let digest = model.digest, model.reportPeriod == model.period {
                spendBody(digest, report: report)
                    .opacity(model.isLoading ? 0.6 : 1)
                    .animation(.easeOut(duration: 0.15), value: model.isLoading)
            } else if let error = report.summaryError {
                AgentHomeUsageNote(icon: "exclamationmark.triangle", text: error)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }

    @ViewBuilder
    private func spendBody(_ digest: ProviderUsageDigest, report: ProviderUsageReport) -> some View {
        HStack(spacing: 10) {
            AgentHomeUsageStatTile(
                title: String(localized: "agentHome.usage.cost", defaultValue: "Cost"),
                value: AgentHomeUsageFormat.cost(digest.costUsd),
                detail: digest.unpricedRecords > 0
                    ? String(localized: "agentHome.usage.unpriced", defaultValue: "\(digest.unpricedRecords) unpriced, so at least this")
                    : nil
            )
            AgentHomeUsageStatTile(
                title: String(localized: "agentHome.usage.tokens", defaultValue: "Tokens"),
                value: AgentHomeUsageFormat.tokens(digest.tokens),
                detail: String(localized: "agentHome.usage.outputTokens", defaultValue: "\(AgentHomeUsageFormat.tokens(digest.outputTokens)) output")
            )
            AgentHomeUsageStatTile(
                title: String(localized: "agentHome.usage.sessions", defaultValue: "Sessions"),
                value: digest.sessions.formatted(),
                detail: digest.sessions > 0
                    ? String(localized: "agentHome.usage.perSession", defaultValue: "\(AgentHomeUsageFormat.cost(digest.costUsd / Double(digest.sessions))) each")
                    : nil
            )
            AgentHomeUsageStatTile(
                title: String(localized: "agentHome.usage.cacheSaved", defaultValue: "Saved by cache"),
                value: AgentHomeUsageFormat.cost(digest.cacheSavingsUsd),
                detail: nil
            )
        }
        if digest.points.isEmpty {
            AgentHomeUsageNote(icon: "chart.bar", text: String(
                localized: "agentHome.usage.noSpend", defaultValue: "No agent use in this period."
            ))
        } else {
            AgentHomeUsageChart(digest: digest, report: report, hourly: model.period == .day)
            HStack(alignment: .top, spacing: 12) {
                AgentHomeUsageBreakdown(
                    title: String(localized: "agentHome.usage.byAccount", defaultValue: "By account"),
                    rows: digest.spenders.map {
                        .init(id: $0.id, label: $0.label, detail: AgentHomeUsageFormat.tokens($0.tokens),
                              costUsd: $0.costUsd, color: AgentHomeUsageColors.color(forSpender: $0.id, in: report))
                    },
                    total: digest.costUsd
                )
                AgentHomeUsageBreakdown(
                    title: String(localized: "agentHome.usage.byModel", defaultValue: "By model"),
                    rows: digest.models.prefix(8).map {
                        .init(id: $0.id, label: $0.model, detail: AgentHomeUsageFormat.tokens($0.tokens),
                              costUsd: $0.costUsd, color: nil)
                    },
                    total: digest.costUsd
                )
            }
        }
        ForEach(Array(digest.sourceProblems.enumerated()), id: \.offset) { _, source in
            Text("\(source.path): \(source.message ?? source.status)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

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
            color = Color(red: 0.89, green: 0.29, blue: 0.28)
        } else if remainingPercent <= 25 {
            title = String(localized: "agentHome.usage.status.low", defaultValue: "Low")
            icon = "exclamationmark.triangle.fill"
            color = AgentHomePalette.needsYou
        } else {
            return nil
        }
    }
}

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

/// Cost per day (or hour), stacked by account, with a tooltip for the hovered bar.
struct AgentHomeUsageChart: View {
    let digest: ProviderUsageDigest
    let report: ProviderUsageReport
    let hourly: Bool

    @State private var selection: Date?

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
        // The bar under the pointer: the latest slot starting at or before it.
        let selectedSlot = selection.flatMap { selected in
            Set(bars.map(\.slot)).filter { $0 <= selected && selected.timeIntervalSince($0) < (hourly ? 3600 : 86_400) }.max()
        }
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
                                selection = proxy.value(atX: location.x - originX, as: Date.self)
                            case .ended:
                                selection = nil
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

    private func bars() -> [Bar] {
        let labels = Dictionary(uniqueKeysWithValues: digest.spenders.map { ($0.id, $0.label) })
        return digest.points.compactMap { point in
            guard let slot = AgentHomeUsageFormat.slotDate(point.slot) else { return nil }
            return Bar(slot: slot, spenderId: point.spenderId, label: labels[point.spenderId] ?? point.spenderId, costUsd: point.costUsd)
        }
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
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.09 : (isHovered ? 0.05 : 0)))
            )
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

    /// A summary slot as a date: `YYYY-MM-DD` at local midnight, or an hour's ISO start.
    static func slotDate(_ slot: String) -> Date? {
        if slot.count == 10 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: slot)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: slot) ?? ISO8601DateFormatter().date(from: slot)
    }
}
