import AppKit
import CmuxAgentHome
import Foundation
import Observation

/// T3 Code threads in Agent Home.
///
/// T3 runs the agents. This model reads T3's local database (read-only) every
/// few seconds into a project → task → sub-thread tree, and opens a task as a
/// cmux workspace: the thread's chat (the agent-chat sidecar's T3 view) on the
/// left and a terminal in the task's folder on the right. Sub-threads open in
/// the same workspace's chat.
@MainActor
@Observable
final class AgentHomeT3Model {
    static let shared = AgentHomeT3Model()

    /// T3 projects, most recently active first.
    private(set) var projects: [T3ProjectNode] = []

    /// The thread each T3 workspace's chat shows, by workspace id.
    private(set) var shownThreadIds: [UUID: String] = [:]

    /// The workspace each opened task lives in, by root thread id.
    private var taskLinks: [String: UUID]
    private var refreshTask: Task<Void, Never>?

    private static let linksDefaultsKey = "agentHomeT3TaskWorkspaces"
    private static let refreshInterval: Duration = .seconds(3)

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.linksDefaultsKey) as? [String: String] ?? [:]
        taskLinks = stored.compactMapValues(UUID.init(uuidString:))
    }

    // MARK: - Reading T3

    /// Starts reading T3's database every few seconds. Safe to call repeatedly.
    func startIfNeeded() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reload()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    /// Reads T3's database now.
    func reload() async {
        let built = await Task.detached(priority: .utility) { () -> [T3ProjectNode]? in
            let reader = T3CodeStateReader()
            guard FileManager.default.fileExists(atPath: reader.databaseURL.path),
                  let threads = try? reader.activeThreads()
            else { return nil }
            return T3ThreadTree.build(threads)
        }.value
        guard let built, built != projects else { return }
        projects = built
    }

    // MARK: - Lookups

    /// The task an open workspace shows, if it's a T3 task.
    func task(forWorkspace workspaceId: UUID) -> T3TaskNode? {
        guard let taskId = taskLinks.first(where: { $0.value == workspaceId })?.key else { return nil }
        return allTasks.first { $0.id == taskId }
    }

    /// The workspace a task is open in, if it still exists.
    func workspaceId(forTask taskId: String, tabManager: TabManager) -> UUID? {
        guard let id = taskLinks[taskId], tabManager.tabs.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// Workspaces that hold T3 tasks; the sidebar lists them as T3 tasks, not as plain tasks.
    var linkedWorkspaceIds: Set<UUID> { Set(taskLinks.values) }

    /// The project a task belongs to.
    func project(of task: T3TaskNode) -> T3ProjectNode? {
        projects.first { project in project.recentTasks.contains { $0.id == task.id } || project.olderTasks.contains { $0.id == task.id } }
    }

    /// The cmux workspace group a T3 project maps to, if any.
    func groupId(for project: T3ProjectNode, tabManager: TabManager) -> UUID? {
        guard !project.id.isEmpty else { return nil }
        return T3Linking.groupId(
            forProjectId: project.id,
            projectName: project.name,
            projectRoot: project.root,
            in: linkGroups(tabManager: tabManager)
        )
    }

    private var allTasks: [T3TaskNode] { projects.flatMap { $0.recentTasks + $0.olderTasks } }

    // MARK: - Opening

    /// Opens a task, or one of its sub-threads, as a cmux task: creates the
    /// workspace on first open, then shows the thread in its chat.
    func open(_ task: T3TaskNode, thread: T3Thread? = nil, tabManager: TabManager) {
        let target = thread ?? task.thread
        if let existing = workspaceId(forTask: task.id, tabManager: tabManager) {
            tabManager.focusTab(existing)
            if shownThreadIds[existing] != target.id {
                shownThreadIds[existing] = target.id
                Task { await navigateChat(inWorkspace: existing, toThread: target.id, tabManager: tabManager) }
            }
            return
        }

        let directory = task.thread.worktreePath ?? task.thread.projectRoot
        let workspace = tabManager.addWorkspace(title: task.thread.title, workingDirectory: directory, select: true)
        if let project = project(of: task) ?? projectStub(for: task) {
            let groupId = groupId(for: project, tabManager: tabManager) ?? (project.id.isEmpty ? nil : tabManager.createWorkspaceGroup(
                name: project.name,
                anchorWorkingDirectory: project.root,
                selectAnchor: false,
                collapseSidebarSelection: false,
                externalID: T3Linking.externalID(forProjectId: project.id)
            ))
            if let groupId { tabManager.addWorkspaceToGroup(workspaceId: workspace.id, groupId: groupId) }
        }
        tabManager.focusTab(workspace.id)
        taskLinks[task.id] = workspace.id
        shownThreadIds[workspace.id] = target.id
        UserDefaults.standard.set(taskLinks.mapValues(\.uuidString), forKey: Self.linksDefaultsKey)

        let workspaceId = workspace.id
        Task { await self.addChat(toWorkspace: workspaceId, threadId: target.id, tabManager: tabManager) }
    }

    /// A project for a task that isn't in the tree yet (a thread started moments ago).
    private func projectStub(for task: T3TaskNode) -> T3ProjectNode? {
        guard let name = task.thread.projectName else { return nil }
        return T3ProjectNode(id: task.thread.projectId, name: name, root: task.thread.projectRoot, recentTasks: [], olderTasks: [])
    }

    /// Puts the thread's chat to the left of the workspace's terminal.
    private func addChat(toWorkspace workspaceId: UUID, threadId: String, tabManager: TabManager) async {
        guard let url = await chatURL(threadId: threadId, tabManager: tabManager),
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
              let terminalId = workspace.focusedPanelId ?? workspace.panels.keys.first
        else { NSSound.beep(); return }
        _ = workspace.newBrowserSplit(
            from: terminalId,
            orientation: .horizontal,
            insertFirst: true,
            url: url,
            focus: true,
            chromeVisibility: .hidden,
            transparentBackground: true,
            initialDividerPosition: 0.62
        )
    }

    /// Points the workspace's chat at another thread (the task's root or a sub-thread).
    private func navigateChat(inWorkspace workspaceId: UUID, toThread threadId: String, tabManager: TabManager) async {
        guard let url = await chatURL(threadId: threadId, tabManager: tabManager),
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceId })
        else { return }
        if let chat = workspace.panels.values.compactMap({ $0 as? BrowserPanel }).first {
            _ = chat.navigate(to: url)
        } else {
            await addChat(toWorkspace: workspaceId, threadId: threadId, tabManager: tabManager)
        }
    }

    /// `<sidecar>/t3/<thread id>?transparent=1`, starting the sidecar if needed.
    private func chatURL(threadId: String, tabManager: TabManager) async -> URL? {
        guard let base = await sidecarBase(tabManager: tabManager),
              let encoded = threadId.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_")))
        else { return nil }
        return URL(string: "\(base)t3/\(encoded)?transparent=1")
    }

    /// The sidecar's base URL with its token, ending in "/", starting the sidecar if needed.
    private func sidecarBase(tabManager: TabManager) async -> String? {
        guard let base = await AppDelegate.shared?.agentChatBrowserBaseURL(tabManager: tabManager, preferredWindow: NSApp.keyWindow) else {
            return nil
        }
        let string = base.absoluteString
        return string.hasSuffix("/") ? string : string + "/"
    }

    // MARK: - New chat

    enum NewChatError: LocalizedError {
        case sidecarUnavailable
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .sidecarUnavailable:
                return String(localized: "agentHome.newChat.sidecarUnavailable", defaultValue: "Agent Chat isn't running. Check the agentChat settings in cmux.json.")
            case .rejected(let message):
                return message
            }
        }
    }

    /// Starts a T3 thread in a project with a first message, then opens it as a task.
    func startNewChat(projectId: String, text: String, tabManager: TabManager) async throws {
        guard let base = await sidecarBase(tabManager: tabManager), let endpoint = URL(string: "\(base)api/t3/threads") else {
            throw NewChatError.sidecarUnavailable
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["projectId": projectId, "text": text])
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let threadId = body["threadId"] as? String else {
            throw NewChatError.rejected(body["error"] as? String ?? "T3 didn't start the thread.")
        }
        let project = projects.first { $0.id == projectId }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let thread = T3Thread(
            id: threadId,
            projectId: projectId,
            projectName: project?.name,
            projectRoot: project?.root,
            title: firstLine,
            provider: "",
            updatedAt: Date(),
            latestRunStatus: "running"
        )
        open(T3TaskNode(thread: thread), tabManager: tabManager)
        await reload()
    }

    // MARK: - Helpers

    private func linkGroups(tabManager: TabManager) -> [T3LinkGroup] {
        tabManager.workspaceGroups.map { group in
            T3LinkGroup(
                id: group.id,
                name: group.name,
                externalID: group.externalID,
                directory: tabManager.workspaceGroupAnchor(for: group.id)?.currentDirectory
            )
        }
    }
}
