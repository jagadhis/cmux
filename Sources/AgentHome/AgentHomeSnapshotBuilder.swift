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
    static func snapshot(tabManager: TabManager) -> AgentHomeSnapshot {
        let projects = tabManager.workspaceGroups.map { group -> AgentHomeProjectInput in
            var homeTaskId: UUID?
            if case .workspace(let anchorId) = group.anchor { homeTaskId = anchorId }
            return AgentHomeProjectInput(id: group.id, name: group.name, colorHex: group.customColor, homeTaskId: homeTaskId)
        }
        let tasks = tabManager.tabs.map(taskInput(for:))
        return AgentHomeProjection.snapshot(projects: projects, tasks: tasks)
    }

    static func taskInput(for workspace: Workspace) -> AgentHomeTaskInput {
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
            agents: agents(in: workspace, orderedPanelIds: orderedPanelIds)
        )
    }

    static func agents(in workspace: Workspace, orderedPanelIds: [UUID]) -> [AgentHomeAgent] {
        let states = workspace.agentLifecycleStatesByPanelId
        return orderedPanelIds.flatMap { panelId -> [AgentHomeAgent] in
            guard let panel = workspace.panels[panelId], let byAgent = states[panelId] else { return [] }
            return byAgent.keys.sorted().compactMap { agentKey in
                guard let state = byAgent[agentKey].flatMap(agentState(for:)) else { return nil }
                return AgentHomeAgent(
                    id: "\(panelId.uuidString):\(agentKey)",
                    kind: AgentHomeAgentKind(hookAgentKey: agentKey),
                    title: workspace.panelCustomTitles[panelId] ?? panel.displayTitle,
                    state: state
                )
            }
        }
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
