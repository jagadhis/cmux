import AppKit
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
        .agentHomePageBackground()
        .onAppear {
            model.use(tabManager: tabManager)
            // Opening the page is a user action, so it may start the sidecar.
            Task { await model.refresh(startsSidecar: true) }
        }
        .agentHomePolling { [AgentHomeUsageModel.shared.poller] }
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
                Task { await model.refresh(startsSidecar: true) }
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
