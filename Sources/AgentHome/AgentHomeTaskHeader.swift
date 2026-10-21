import CmuxAgentHome
import SwiftUI

struct AgentHomeTaskHeader: View {
    let task: AgentHomeTask
    let projectName: String?
    let projectColorHex: String?
    let mode: AgentHomeTaskViewState.Mode
    let onModeChange: (AgentHomeTaskViewState.Mode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let projectName {
                HStack(spacing: 6) {
                    AgentHomeProjectBadge(name: projectName, colorHex: projectColorHex)
                        .scaleEffect(0.85)
                    Text(projectName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .center, spacing: 12) {
                Text(task.input.title)
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.3)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Picker("", selection: Binding(get: { mode }, set: onModeChange)) {
                    Text(String(localized: "agentHome.mode.overview", defaultValue: "Overview"))
                        .tag(AgentHomeTaskViewState.Mode.overview)
                    Text(String(localized: "agentHome.mode.sessions", defaultValue: "Sessions"))
                        .tag(AgentHomeTaskViewState.Mode.sessions)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.top, 3)
            AgentHomeTaskMetaRow(task: task)
                .padding(.top, 9)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }
}

private struct AgentHomeTaskMetaRow: View {
    let task: AgentHomeTask

    var body: some View {
        HStack(spacing: 16) {
            if let branch = task.input.branch {
                meta(symbol: "arrow.triangle.branch") {
                    Text(branch).font(.system(size: 11.5, design: .monospaced))
                }
            }
            if let pr = task.input.pullRequest {
                meta(symbol: "arrow.triangle.pull") {
                    Text(verbatim: "#\(pr.number)")
                    if !pr.checks.isEmpty { AgentHomeCheckBars(checks: pr.checks) }
                }
            }
            if !task.input.agents.isEmpty {
                meta(symbol: "person.2") {
                    Text(agentCountText)
                }
            }
            if let startedAt = task.startedAt {
                meta(symbol: "clock") {
                    Text(AgentHomeFormat.elapsed(since: startedAt))
                }
            }
            if let cost = task.estimatedCostUSD {
                Text(cost, format: .currency(code: "USD"))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var agentCountText: String {
        let total = task.input.agents.count
        let live = task.liveAgentCount
        let agents = total == 1
            ? String(localized: "agentHome.meta.oneAgent", defaultValue: "1 agent")
            : String(localized: "agentHome.meta.agents", defaultValue: "\(total) agents")
        guard live > 0 else { return agents }
        return agents + " · " + String(localized: "agentHome.meta.live", defaultValue: "\(live) live")
    }

    private func meta<Content: View>(symbol: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11))
            content()
        }
    }
}
