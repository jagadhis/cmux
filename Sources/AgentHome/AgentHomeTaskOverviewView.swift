import CMUXAgentLaunch
import CmuxAgentHome
import CmuxGit
import CmuxWorkspaces
import SwiftUI

/// Wraps a window's workspace area for Agent Home: while `isActive`, a task
/// header with the Overview / Sessions switch sits above the workspace, and
/// the task overview fills the area while Overview is showing.
///
/// Terminals are portal-hosted AppKit views that can draw above SwiftUI, so
/// the overview never sits on top of live terminals. The caller hides the
/// selected workspace while ``hidesSelectedWorkspace(tabManager:)`` is true,
/// through the same visibility flag workspace switching uses. The wrapper
/// stays in the tree when inactive so toggling the sidebar never remounts
/// terminals.
struct AgentHomeWorkspaceArea<Content: View>: View {
    let isActive: Bool
    @ObservedObject var tabManager: TabManager
    let content: Content

    private let feedModel = AgentHomeFeedModel.shared
    private let viewState = AgentHomeTaskViewState.shared

    /// Whether Overview is showing for the selected workspace, so its terminals should be hidden.
    @MainActor
    static func hidesSelectedWorkspace(isActive: Bool, tabManager: TabManager) -> Bool {
        guard isActive,
              let selectedId = tabManager.selectedTabId,
              let workspace = tabManager.tabs.first(where: { $0.id == selectedId })
        else { return false }
        let hasAgents = !AgentHomeSnapshotBuilder.agents(
            in: workspace,
            orderedPanelIds: workspace.sidebarOrderedPanelIds()
        ).isEmpty
        return AgentHomeTaskViewState.shared.mode(forTaskId: selectedId, hasAgents: hasAgents) == .overview
    }

    var body: some View {
        let task: AgentHomeTask? = isActive ? selectedTask() : nil
        let mode = task.map(viewState.mode(for:)) ?? .sessions

        VStack(spacing: 0) {
            if let task {
                let group = workspaceGroup(of: task)
                AgentHomeTaskHeader(
                    task: task,
                    projectName: group?.name,
                    projectColorHex: group?.customColor,
                    mode: mode,
                    onModeChange: { viewState.setMode($0, for: task.id) }
                )
            }
            ZStack {
                content
                if let task, mode == .overview {
                    AgentHomeTaskOverview(task: task, actions: actions(for: task))
                        .id(task.id)
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: mode)
        .task(id: isActive ? feedModel.resolutionToken : -1) {
            guard isActive else { return }
            await feedModel.resolveTargets(for: feedModel.workstreamIDs)
        }
    }

    private func selectedTask() -> AgentHomeTask? {
        let snapshot = AgentHomeSnapshotBuilder.snapshot(tabManager: tabManager, feed: feedModel.signals())
        return tabManager.selectedTabId.flatMap(snapshot.task(id:))
    }

    private func workspaceGroup(of task: AgentHomeTask) -> WorkspaceGroup? {
        guard let projectId = task.input.projectId else { return nil }
        return tabManager.workspaceGroups.first { $0.id == projectId }
    }

    private func actions(for task: AgentHomeTask) -> AgentHomeOverviewActions {
        AgentHomeOverviewActions(
            reply: { request, mode in feedModel.reply(to: request, mode: mode) },
            openTerminal: { agent in
                viewState.setMode(.sessions, for: task.id)
                tabManager.focusTab(task.id, surfaceId: AgentHomeSnapshotBuilder.panelId(forAgentId: agent.id))
            },
            send: { agent, text in
                guard let panelId = AgentHomeSnapshotBuilder.panelId(forAgentId: agent.id) else { return }
                FeedJumpResolver.sendText(workspaceId: task.id.uuidString, surfaceId: panelId.uuidString, text: text)
            }
        )
    }
}

/// What the overview can do, passed down as closures so card views hold no stores.
struct AgentHomeOverviewActions {
    var reply: (AgentHomePermissionRequest, WorkstreamPermissionMode) -> Void
    var openTerminal: (AgentHomeAgent) -> Void
    var send: (AgentHomeAgent, String) -> Void
}

// MARK: - Header

private struct AgentHomeTaskHeader: View {
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

// MARK: - Overview

private struct AgentHomeTaskOverview: View {
    let task: AgentHomeTask
    let actions: AgentHomeOverviewActions

    @State private var changedFiles: [AgentHomeChangedFile] = []

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(alignment: .top, spacing: 22) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        AgentHomeSectionHeader(
                            title: String(localized: "agentHome.overview.agents", defaultValue: "Agents"),
                            detail: task.input.agents.isEmpty ? nil : "\(task.input.agents.count)"
                        )
                        if task.input.agents.isEmpty {
                            AgentHomeEmptyAgents()
                        } else {
                            ForEach(task.input.agents) { agent in
                                AgentHomeAgentCard(
                                    agent: agent,
                                    onReply: actions.reply,
                                    onOpenTerminal: { actions.openTerminal(agent) }
                                )
                            }
                        }
                    }
                    .padding(.bottom, 90)
                }
                .scrollIndicators(.never)

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 18) {
                        if let pr = task.input.pullRequest {
                            AgentHomePullRequestCard(pullRequest: pr, branch: task.input.branch)
                        }
                        AgentHomeChangesCard(files: changedFiles)
                    }
                    .padding(.bottom, 90)
                }
                .scrollIndicators(.never)
                .frame(width: 270)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)

            AgentHomeComposer(agents: task.input.agents, onSend: actions.send)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task(id: task.input.directory) {
            await loadChanges()
        }
    }

    /// Loads the working tree's changes, then refreshes every 10 s while the overview is open.
    private func loadChanges() async {
        guard let directory = task.input.directory else { return }
        let service = WorkspaceChangesService()
        while !Task.isCancelled {
            if let result = try? await service.changedFiles(forDirectory: directory) {
                changedFiles = result.files.map {
                    AgentHomeChangedFile(path: $0.path, additions: $0.additions, deletions: $0.deletions)
                }
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }
}

private struct AgentHomeSectionHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(spacing: 7) {
            Text(title).fontWeight(.semibold).foregroundStyle(.tertiary)
            if let detail { Text(detail).foregroundStyle(.secondary) }
        }
        .font(.system(size: 11.5))
    }
}

private struct AgentHomeEmptyAgents: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "agentHome.overview.noAgents.title", defaultValue: "No agents in this task yet"))
                .font(.system(size: 13, weight: .medium))
            Text(String(localized: "agentHome.overview.noAgents.body", defaultValue: "Start Claude, Codex or OpenCode in one of its terminals and it shows up here with its plan and live activity."))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .agentHomeCard()
    }
}

// MARK: - Agent card

private struct AgentHomeAgentCard: View {
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

private struct AgentHomeAgentAvatar: View {
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
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color.primary.opacity(0.85)
        case .opencode: return Color(red: 0.55, green: 0.80, blue: 0.25)
        case .other: return Color.secondary
        }
    }
}

private struct AgentHomeStatePill: View {
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

    @State private var spinning = false

    var body: some View {
        ZStack {
            if status == .completed {
                Circle().fill(AgentHomePalette.done)
                Image(systemName: "checkmark").font(.system(size: 7.5, weight: .heavy)).foregroundStyle(.black.opacity(0.75))
            } else if isCurrent && isWaiting {
                Circle().strokeBorder(AgentHomePalette.needsYou, lineWidth: 1.3)
            } else if isCurrent {
                Circle().strokeBorder(AgentHomePalette.running.opacity(0.25), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(AgentHomePalette.running, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .onAppear {
                        withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spinning = true }
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
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.25)))
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

// MARK: - Side column

private struct AgentHomePullRequestCard: View {
    let pullRequest: AgentHomePullRequest
    let branch: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AgentHomeSectionHeader(title: String(localized: "agentHome.overview.pullRequest", defaultValue: "Pull request"))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "#\(pullRequest.number) \(pullRequest.title)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(2)
                Text(stateText + (branch.map { " · \($0)" } ?? ""))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !pullRequest.checks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(pullRequest.checks, id: \.name) { check in
                            HStack(spacing: 8) {
                                Circle().fill(color(for: check.outcome)).frame(width: 6, height: 6)
                                Text(check.name).font(.system(size: 12))
                            }
                        }
                    }
                    .padding(.top, 7)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .agentHomeCard()
            .onTapGesture { if let url = pullRequest.url { NSWorkspace.shared.open(url) } }
        }
    }

    private var stateText: String {
        switch pullRequest.state {
        case .open: return String(localized: "agentHome.pr.open", defaultValue: "Open")
        case .merged: return String(localized: "agentHome.pr.merged", defaultValue: "Merged")
        case .closed: return String(localized: "agentHome.pr.closed", defaultValue: "Closed")
        }
    }

    private func color(for outcome: AgentHomePullRequest.Check.Outcome) -> Color {
        switch outcome {
        case .passed: return AgentHomePalette.done
        case .pending: return AgentHomePalette.needsYou
        case .failed: return .red
        }
    }
}

private struct AgentHomeChangesCard: View {
    let files: [AgentHomeChangedFile]

    var body: some View {
        let additions = files.reduce(0) { $0 + $1.additions }
        let deletions = files.reduce(0) { $0 + $1.deletions }
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                AgentHomeSectionHeader(title: String(localized: "agentHome.overview.changes", defaultValue: "Changes"))
                if !files.isEmpty {
                    Text(verbatim: "+\(additions)").foregroundStyle(AgentHomePalette.done)
                    Text(verbatim: "−\(deletions)").foregroundStyle(.red.opacity(0.8))
                }
            }
            .font(.system(size: 11.5).monospacedDigit())
            VStack(alignment: .leading, spacing: 0) {
                if files.isEmpty {
                    Text(String(localized: "agentHome.overview.noChanges", defaultValue: "No uncommitted changes"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(files.prefix(12), id: \.path) { file in
                        AgentHomeFileRow(file: file)
                    }
                    if files.count > 12 {
                        Text(String(localized: "agentHome.overview.moreFiles", defaultValue: "\(files.count - 12) more files"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 5)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .agentHomeCard()
        }
    }
}

private struct AgentHomeFileRow: View {
    let file: AgentHomeChangedFile

    var body: some View {
        HStack(spacing: 8) {
            (Text(file.directory).foregroundStyle(.tertiary) + Text(file.fileName))
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 6)
            Text(verbatim: "+\(file.additions)").foregroundStyle(AgentHomePalette.done)
            Text(verbatim: "−\(file.deletions)").foregroundStyle(.red.opacity(0.8))
            AgentHomeDiffBar(additions: file.additions, deletions: file.deletions)
        }
        .font(.system(size: 11).monospacedDigit())
        .padding(.vertical, 5)
    }
}

private struct AgentHomeDiffBar: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        let total = max(additions + deletions, 1)
        let added = Int((Double(additions) / Double(total) * 5).rounded())
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < added ? AgentHomePalette.done : (deletions > 0 ? Color.red.opacity(0.75) : Color.primary.opacity(0.12)))
                    .frame(width: 4, height: 7)
            }
        }
    }
}

// MARK: - Composer

private struct AgentHomeComposer: View {
    let agents: [AgentHomeAgent]
    let onSend: (AgentHomeAgent, String) -> Void

    @State private var text = ""
    @State private var targetId: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        let target = agents.first { $0.id == targetId } ?? agents.first { $0.state != .idle } ?? agents.first
        HStack(spacing: 10) {
            TextField(
                agents.isEmpty
                    ? String(localized: "agentHome.composer.noAgents", defaultValue: "Start an agent in this task to message it")
                    : String(localized: "agentHome.composer.placeholder", defaultValue: "Tell the agents what to do next…"),
                text: $text
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($isFocused)
            .disabled(agents.isEmpty)
            .onSubmit { send(to: target) }

            if let target {
                Menu {
                    ForEach(agents) { agent in
                        Button(agent.title) { targetId = agent.id }
                    }
                } label: {
                    Text(target.title).lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 12))
            }

            Button { send(to: target) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(text.isEmpty ? Color.primary.opacity(0.12) : Color.primary))
                    .foregroundStyle(text.isEmpty ? Color.secondary : Color(nsColor: .windowBackgroundColor))
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || target == nil)
        }
        .padding(.leading, 14)
        .padding(.trailing, 9)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isFocused ? AgentHomePalette.running.opacity(0.55) : Color.primary.opacity(0.1), lineWidth: isFocused ? 1 : 0.5)
        )
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    private func send(to target: AgentHomeAgent?) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target, !message.isEmpty else { return }
        onSend(target, message)
        text = ""
    }
}

// MARK: - Shared pieces

/// Text with a light sweeping across it, for an agent's live activity.
private struct AgentHomeShimmerText: View {
    let text: String
    @State private var phase: CGFloat = -1

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .overlay(
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.55), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.45)
                    .offset(x: phase * proxy.size.width * 1.4)
                }
                .mask(Text(text))
                .allowsHitTesting(false)
            )
            .onAppear {
                withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

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
    fileprivate func agentHomeCard(highlight: Color? = nil, hovered: Bool = false) -> some View {
        modifier(AgentHomeCardModifier(highlight: highlight, hovered: hovered))
    }
}

enum AgentHomeFormat {
    private static let elapsedFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// Elapsed time such as "38m" or "2h 14m"; under a minute reads "now".
    static func elapsed(since date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        guard interval >= 60 else { return String(localized: "agentHome.time.now", defaultValue: "now") }
        return elapsedFormatter.string(from: interval) ?? ""
    }

    /// Relative time such as "23 hr. ago".
    static func relative(_ date: Date, now: Date = Date()) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: now)
    }
}
