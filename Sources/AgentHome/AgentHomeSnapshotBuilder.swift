import CmuxAgentHome
import CmuxSidebar
import CmuxWorkspaces
import Foundation

/// Builds the Agent Home snapshot from a window's live workspaces and groups.
///
/// Reads only observable workspace state, so a SwiftUI body that calls it
/// re-renders when lifecycle, branch, PR or status changes.
@MainActor
enum AgentHomeSnapshotBuilder {
    static func snapshot(
        tabManager: TabManager,
        feed: [String: AgentHomeFeedSignals] = [:]
    ) -> AgentHomeSnapshot {
        let projects = tabManager.workspaceGroups.map { group -> AgentHomeProjectInput in
            var homeTaskId: UUID?
            if case .workspace(let anchorId) = group.anchor { homeTaskId = anchorId }
            return AgentHomeProjectInput(id: group.id, name: group.name, colorHex: group.customColor, homeTaskId: homeTaskId)
        }
        let tasks = tabManager.tabs.map { taskInput(for: $0, feed: feed) }
        return AgentHomeProjection.snapshot(projects: projects, tasks: tasks)
    }

    static func taskInput(for workspace: Workspace, feed: [String: AgentHomeFeedSignals] = [:]) -> AgentHomeTaskInput {
        let orderedPanelIds = workspace.sidebarOrderedPanelIds()
        let branch = workspace.sidebarGitBranchesInDisplayOrder(orderedPanelIds: orderedPanelIds).first
        let pullRequest = workspace.sidebarPullRequestsInDisplayOrder(orderedPanelIds: orderedPanelIds).first
        return AgentHomeTaskInput(
            id: workspace.id,
            title: workspace.title,
            projectId: workspace.groupId,
            lane: lane(for: workspace.effectiveTaskStatus),
            branch: branch?.branch,
            directory: workspace.currentDirectory,
            pullRequest: pullRequest.map(pullRequestInput(for:)),
            agents: agents(in: workspace, orderedPanelIds: orderedPanelIds, feed: feed)
        )
    }

    static func agents(
        in workspace: Workspace,
        orderedPanelIds: [UUID],
        feed: [String: AgentHomeFeedSignals] = [:]
    ) -> [AgentHomeAgent] {
        let states = workspace.agentLifecycleStatesByPanelId
        let usageByKey = workspace.sidebarMetadata.agentUsageByStatusKey
        return orderedPanelIds.flatMap { panelId -> [AgentHomeAgent] in
            guard workspace.panels[panelId] != nil, let byAgent = states[panelId] else { return [] }
            let signals = feed[panelId.uuidString.uppercased()]
            return byAgent.keys.sorted().compactMap { agentKey in
                guard !AgentHibernationLifecycleStatusKeys.isManualKey(agentKey),
                      let state = byAgent[agentKey].flatMap(agentState(for:))
                else { return nil }
                let usage = usageByKey[agentKey]
                return AgentHomeAgent(
                    id: "\(panelId.uuidString):\(agentKey)",
                    kind: AgentHomeAgentKind(hookAgentKey: agentKey),
                    title: userTitle(for: panelId, in: workspace)
                        ?? signals?.sessionTitle
                        ?? AgentHomeAgentKind(hookAgentKey: agentKey).displayName,
                    modelName: usage?.modelName,
                    state: state,
                    startedAt: signals?.startedAt,
                    lastActivityAt: signals?.lastActivityAt,
                    contextFraction: usage?.contextFraction,
                    estimatedCostUSD: usage?.estimatedCostUSD,
                    currentActivity: state == .idle ? nil : signals?.currentActivity,
                    lastSummary: signals?.lastSummary,
                    plan: signals?.plan ?? [],
                    pendingPermission: signals?.pendingPermission
                )
            }
        }
    }

    /// A tab title the user set. Auto titles (the running command) aren't
    /// good card titles, so they lose to the session's first prompt.
    static func userTitle(for panelId: UUID, in workspace: Workspace) -> String? {
        guard let title = workspace.panelCustomTitles[panelId] else { return nil }
        let source = workspace.panelCustomTitleSources[panelId] ?? .user
        return source == .user ? title : nil
    }

    /// The terminal panel an agent card runs in, from its id (`<panel uuid>:<agent key>`).
    static func panelId(forAgentId agentId: String) -> UUID? {
        agentId.split(separator: ":").first.flatMap { UUID(uuidString: String($0)) }
    }

    static func agentState(for state: AgentHibernationLifecycleState) -> AgentHomeAgentState? {
        switch state {
        case .needsInput: return .needsYou
        case .running, .backgroundWorkPending: return .running
        case .idle: return .idle
        case .unknown: return nil
        }
    }

    static func lane(for status: WorkspaceTaskStatus) -> AgentHomeTaskLane {
        switch status {
        case .todo: return .todo
        case .working: return .working
        case .needsAttention: return .needsAttention
        case .review: return .review
        case .done: return .done
        }
    }

    static func pullRequestInput(for state: SidebarPullRequestState) -> AgentHomePullRequest {
        let status: AgentHomePullRequest.State
        switch state.status {
        case .open: status = .open
        case .merged: status = .merged
        case .closed: status = .closed
        }
        return AgentHomePullRequest(number: state.number, title: state.label, url: state.url, state: status)
    }
}
