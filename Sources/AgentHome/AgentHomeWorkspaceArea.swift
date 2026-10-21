import AppKit
import CMUXAgentLaunch
import CmuxAgentHome
import CmuxAppKitSupportUI
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
///
/// The header and pages follow the window's resolved terminal scheme, the same
/// one the panes and chat under them use, so Agent Home never shows a light
/// header over a dark terminal backdrop (or the reverse) when the terminal
/// theme and the app appearance disagree.
struct AgentHomeWorkspaceArea<Content: View>: View {
    let isActive: Bool
    @ObservedObject var tabManager: TabManager
    let appearance: WindowAppearanceSnapshot
    let content: Content

    /// Bumped when the selected workspace changes in a way `body` can't observe.
    @State private var workspaceChanges = 0

    // Computed, not stored: ContentView builds this wrapper on every render,
    // Agent Home or not, and the models are only needed while it's active.
    private var feedModel: AgentHomeFeedModel { .shared }
    private var viewState: AgentHomeTaskViewState { .shared }
    private var t3Model: AgentHomeT3Model { .shared }

    /// Whether Overview is showing for the selected workspace, so its terminals should be hidden.
    @MainActor
    static func hidesSelectedWorkspace(isActive: Bool, tabManager: TabManager) -> Bool {
        if isActive && AgentHomeTaskViewState.shared.page != nil { return true }
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
        let _ = workspaceChanges
        let task: AgentHomeTask? = isActive ? selectedTask() : nil
        let t3Task: T3TaskNode? = isActive ? tabManager.selectedTabId.flatMap(t3Model.task(forWorkspace:)) : nil
        let mode = task.map(viewState.mode(for:)) ?? .sessions

        let page = isActive ? viewState.page : nil
        VStack(spacing: 0) {
            header(page: page, task: task, t3Task: t3Task, mode: mode)
                .agentHomeAppearance(appearance)
            ZStack {
                // Terminals resize with every animated frame, so their area never animates;
                // only the page and overview layered above it fade.
                content
                    .transaction { $0.animation = nil }
                pageLayer(page: page, task: task, t3Task: t3Task, mode: mode)
                    .agentHomeAppearance(appearance)
                    .animation(.easeOut(duration: 0.18), value: mode)
                    .animation(.easeOut(duration: 0.18), value: page)
            }
        }
        .task(id: isActive ? feedModel.resolutionToken : -1) {
            guard isActive else { return }
            await feedModel.resolveTargets(for: feedModel.workstreamIDs)
        }
        .onAppear { if isActive { t3Model.use(tabManager: tabManager) } }
        .onChange(of: isActive) { _, active in if active { t3Model.use(tabManager: tabManager) } }
        // The task header and overview show T3 tasks too, with or without the sidebar.
        .agentHomePolling(isEnabled: isActive) { [AgentHomeT3Model.shared.poller] }
        .agentHomeWatchesWorkspaces(isActive ? selectedWorkspaces : [], token: $workspaceChanges)
    }

    /// The task header above the workspace, if a task is selected and no page covers it.
    @ViewBuilder
    private func header(page: AgentHomeTaskViewState.Page?, task: AgentHomeTask?, t3Task: T3TaskNode?, mode: AgentHomeTaskViewState.Mode) -> some View {
        if page != nil {
            EmptyView()
        } else if let task, let t3Task {
            let shownId = t3Model.shownThreadIds[task.id] ?? t3Task.thread.id
            AgentHomeT3TaskHeader(
                task: t3Task,
                projectName: t3Model.project(of: t3Task)?.name ?? t3Task.thread.projectName,
                shownSubThread: shownId == t3Task.thread.id ? nil : t3Task.thread(withId: shownId),
                mode: mode,
                onModeChange: { viewState.setMode($0, for: task.id) },
                onOpenRoot: { t3Model.open(t3Task, tabManager: tabManager) },
                onOpenThread: { t3Model.open(t3Task, thread: $0, tabManager: tabManager) },
                onVerify: { t3Model.verify(t3Task, tabManager: tabManager) }
            )
        } else if let task {
            let group = workspaceGroup(of: task)
            AgentHomeTaskHeader(
                task: task,
                projectName: group?.name,
                projectColorHex: group?.customColor,
                mode: mode,
                onModeChange: { viewState.setMode($0, for: task.id) }
            )
        }
    }

    /// The page or overview shown over the selected workspace, if any.
    @ViewBuilder
    private func pageLayer(page: AgentHomeTaskViewState.Page?, task: AgentHomeTask?, t3Task: T3TaskNode?, mode: AgentHomeTaskViewState.Mode) -> some View {
        if case .pullRequest(let ref) = page {
            AgentHomePullRequestDetailView(ref: ref, tabManager: tabManager)
                .id(ref)
                .transition(.opacity)
        } else if page == .usage {
            AgentHomeUsageView(tabManager: tabManager)
                .transition(.opacity)
        } else if page == .pullRequests {
            AgentHomePullRequestsView(
                tabManager: tabManager,
                onReviewWithAgent: { pullRequest in
                    t3Model.openNewChat(
                        projectId: AgentHomePullRequestsModel.shared.project(for: pullRequest)?.id,
                        text: AgentHomePullRequestsModel.reviewPrompt(for: pullRequest),
                        tabManager: tabManager
                    )
                },
                onOpenThread: { link in
                    t3Model.openTask(id: link.taskId, threadId: link.threadId, tabManager: tabManager)
                }
            )
            .transition(.opacity)
        } else if let task, mode == .overview {
            if let t3Task {
                AgentHomeT3Overview(
                    task: t3Task,
                    shownThreadId: t3Model.shownThreadIds[task.id],
                    workspaceId: task.id,
                    tabManager: tabManager,
                    onOpen: { thread in
                        viewState.setMode(.sessions, for: task.id)
                        t3Model.open(t3Task, thread: thread, tabManager: tabManager)
                    },
                    onOpenThread: { threadId in
                        viewState.setMode(.sessions, for: task.id)
                        t3Model.openThread(id: threadId, tabManager: tabManager)
                    },
                    onStartChat: { prompt in
                        t3Model.openNewChat(projectId: t3Task.thread.projectId, text: prompt, tabManager: tabManager)
                    }
                )
                .id(task.id)
                .transition(.opacity)
            } else {
                AgentHomeTaskOverview(task: task, actions: actions(for: task))
                    .id(task.id)
                    .transition(.opacity)
            }
        }
    }

    private var selectedWorkspaces: [Workspace] {
        tabManager.selectedTabId.flatMap { id in tabManager.tabs.first { $0.id == id } }.map { [$0] } ?? []
    }

    /// The selected workspace as a task; only its input is built, not the whole sidebar snapshot.
    private func selectedTask() -> AgentHomeTask? {
        guard let selectedId = tabManager.selectedTabId,
              let workspace = tabManager.tabs.first(where: { $0.id == selectedId })
        else { return nil }
        return AgentHomeTask(input: AgentHomeSnapshotBuilder.taskInput(for: workspace, feed: feedModel.signals()))
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
            },
            openFile: { path in
                AgentHomeSessionFileOpener.open(path, inWorkspace: task.id, tabManager: tabManager)
            }
        )
    }
}

/// What the overview can do, passed down as closures so card views hold no stores.
struct AgentHomeOverviewActions {
    var reply: (AgentHomePermissionRequest, WorkstreamPermissionMode) -> Void
    var openTerminal: (AgentHomeAgent) -> Void
    var send: (AgentHomeAgent, String) -> Void
    var openFile: (String) -> Void
}

/// The colour Agent Home pages paint behind their content: the terminal
/// background composited over the window base for the resolved scheme, so a
/// page swapped in over a workspace matches the panes it replaces.
private struct AgentHomePageBackgroundKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    var agentHomePageBackground: Color? {
        get { self[AgentHomePageBackgroundKey.self] }
        set { self[AgentHomePageBackgroundKey.self] = newValue }
    }
}

extension View {
    /// Puts an Agent Home subtree on the window's resolved terminal scheme and page colour.
    func agentHomeAppearance(_ appearance: WindowAppearanceSnapshot) -> some View {
        environment(\.colorScheme, appearance.resolvedColorScheme)
            .environment(\.agentHomePageBackground, Color(nsColor: appearance.resolvedChromeBackgroundColor))
    }

    /// Paints an Agent Home page's background, falling back to the system
    /// background outside a workspace area.
    func agentHomePageBackground() -> some View {
        modifier(AgentHomePageBackground())
    }
}

private struct AgentHomePageBackground: ViewModifier {
    @Environment(\.agentHomePageBackground) private var color

    func body(content: Content) -> some View {
        if let color {
            content.background(color)
        } else {
            content.background(.background)
        }
    }
}
