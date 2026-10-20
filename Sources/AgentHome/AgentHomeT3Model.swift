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
///
/// Settled tasks (verified in T3 or here) aren't read unless open in cmux.
/// A finished task is done until the user verifies it; verifying settles it in
/// T3, closes its workspace and moves on to the next task waiting for review.
@MainActor
@Observable
final class AgentHomeT3Model {
    static let shared = AgentHomeT3Model()

    /// T3 projects, most recently active first.
    private(set) var projects: [T3ProjectNode] = []
    /// Every T3 project by name, including ones with no open work, for New chat.
    private(set) var allProjects: [T3CodeStateReader.Project] = []

    /// The thread each T3 workspace's chat shows, by workspace id.
    private(set) var shownThreadIds: [UUID: String] = [:]

    /// The task just verified, for the sidebar's undo toast.
    private(set) var lastVerified: T3TaskNode?
    /// A T3 command that failed, for the sidebar's toast.
    private(set) var lastError: String?

    /// The workspace each opened task lives in, by root thread id.
    private var taskLinks: [String: UUID]
    /// Tasks verified here that T3's database doesn't show as settled yet.
    private var verifying: Set<String> = []
    /// The tree as last read, before hiding tasks being verified.
    private var readProjects: [T3ProjectNode] = []
    private weak var tabManager: TabManager?
    /// The sidecar's base URL as last returned. cmux runs one sidecar lookup at a
    /// time and turns away a second, so thread actions reuse the last one.
    private var knownSidecarBase: String?
    private var lastVerifyAt = Date.distantPast
    private var refreshTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    private static let linksDefaultsKey = "agentHomeT3TaskWorkspaces"
    private static let refreshInterval: Duration = .seconds(3)

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.linksDefaultsKey) as? [String: String] ?? [:]
        taskLinks = stored.compactMapValues(UUID.init(uuidString:))
    }

    // MARK: - Reading T3

    /// Starts reading T3's database every few seconds. Safe to call repeatedly.
    func startIfNeeded(tabManager: TabManager) {
        self.tabManager = tabManager
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
        let openTaskIds = Set(taskLinks.compactMap { id, workspace in
            tabManager?.tabs.contains { $0.id == workspace } == true ? id : nil
        })
        let read = await Task.detached(priority: .utility) { () -> ([T3ProjectNode], [T3CodeStateReader.Project])? in
            let reader = T3CodeStateReader()
            guard FileManager.default.fileExists(atPath: reader.databaseURL.path),
                  let threads = try? reader.activeThreads(openTaskIds: openTaskIds)
            else { return nil }
            return (T3ThreadTree.build(threads), (try? reader.projects()) ?? [])
        }.value
        guard let (built, all) = read else { return }
        if all != allProjects { allProjects = all }
        readProjects = built
        // Stop hiding a verified task once T3 shows it settled or no longer lists it.
        let listed = Dictionary(built.flatMap { $0.recentTasks + $0.olderTasks }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        verifying = verifying.filter { listed[$0].map { !$0.thread.isSettled } ?? false }
        publish()
    }

    /// Publishes the tree, without tasks being verified or settled tasks that are no longer open.
    private func publish() {
        let visible = readProjects.compactMap { project -> T3ProjectNode? in
            var project = project
            let keep = { (task: T3TaskNode) in
                !self.verifying.contains(task.id) && (!task.thread.isSettled || self.taskLinks[task.id] != nil)
            }
            project.recentTasks = project.recentTasks.filter(keep)
            project.olderTasks = project.olderTasks.filter(keep)
            return project.recentTasks.isEmpty && project.olderTasks.isEmpty ? nil : project
        }
        if visible != projects { projects = visible }
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
        AgentHomeTaskViewState.shared.showsPullRequests = false
        let target = thread ?? task.thread
        if target.hasUnseenResult { markSeen(target.id, tabManager: tabManager) }
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
            return knownSidecarBase
        }
        let string = base.absoluteString
        knownSidecarBase = string.hasSuffix("/") ? string : string + "/"
        return knownSidecarBase
    }

    /// Opens a task by id, reading it from T3 when it isn't listed (a settled task).
    func openTask(id taskId: String, threadId: String? = nil, tabManager: TabManager) {
        func show(_ task: T3TaskNode) {
            let thread = ([task.thread] + task.subThreads).first { $0.id == threadId }
            open(task, thread: thread == task.thread ? nil : thread, tabManager: tabManager)
        }
        if let task = allTasks.first(where: { $0.id == taskId }) { return show(task) }
        Task {
            let task = await Task.detached(priority: .userInitiated) { () -> T3TaskNode? in
                let threads = (try? T3CodeStateReader().activeThreads(openTaskIds: [taskId])) ?? []
                return T3ThreadTree.build(threads).flatMap { $0.recentTasks + $0.olderTasks }.first { $0.id == taskId }
            }.value
            if let task { show(task) } else { NSSound.beep() }
        }
    }

    // MARK: - Reviewing

    /// Tasks whose agents finished and that wait for the user to verify them, in sidebar order.
    var tasksToVerify: [T3TaskNode] { allTasks.filter { $0.status == .done } }

    /// Marks a task verified: settles it in T3 (like T3's Settle), opens the
    /// next task waiting for review if this one was on screen, and closes its
    /// workspace. Undo puts it back with ``undoVerify(tabManager:)``.
    func verify(_ task: T3TaskNode, tabManager: TabManager) {
        // The next row slides under the pointer when a task leaves the list;
        // a quick second click shouldn't verify it too.
        guard Date().timeIntervalSince(lastVerifyAt) > 0.8 else { return }
        lastVerifyAt = Date()
        let workspaceId = workspaceId(forTask: task.id, tabManager: tabManager)
        let wasOnScreen = workspaceId != nil && workspaceId == tabManager.selectedTabId
        let next = tasksToVerify.first { $0.id != task.id }

        verifying.insert(task.id)
        publish()
        showToast(verified: task)
        if wasOnScreen, let next { open(next, tabManager: tabManager) }
        if let workspaceId, let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
           tabManager.closeWorkspaceWithConfirmation(workspace) {
            taskLinks[task.id] = nil
            shownThreadIds[workspaceId] = nil
            UserDefaults.standard.set(taskLinks.mapValues(\.uuidString), forKey: Self.linksDefaultsKey)
        }

        Task {
            do {
                try await threadAction(.settle, threadId: task.id, tabManager: tabManager)
            } catch {
                verifying.remove(task.id)
                publish()
                showToast(error: error.localizedDescription)
            }
            await reload()
        }
    }

    /// Takes back the last verify: un-settles the task in T3 so it's listed again.
    func undoVerify(tabManager: TabManager) {
        guard let task = lastVerified else { return }
        lastVerified = nil
        verifying.remove(task.id)
        Task {
            do {
                try await threadAction(.unsettle, threadId: task.id, tabManager: tabManager)
            } catch {
                showToast(error: error.localizedDescription)
            }
            await reload()
        }
    }

    /// Tells T3 the user has seen a thread's latest result, here or in T3.
    func markSeen(_ threadId: String, tabManager: TabManager) {
        Task {
            try? await threadAction(.visit, threadId: threadId, tabManager: tabManager)
            await reload()
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        lastVerified = nil
        lastError = nil
    }

    private func showToast(verified task: T3TaskNode? = nil, error: String? = nil) {
        lastVerified = task
        lastError = error
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.lastVerified = nil
            self?.lastError = nil
        }
    }

    private enum ThreadAction: String { case settle, unsettle, visit }

    private func threadAction(_ action: ThreadAction, threadId: String, tabManager: TabManager) async throws {
        do {
            let base: String? = if let knownSidecarBase { knownSidecarBase } else { await sidecarBase(tabManager: tabManager) }
            try await threadAction(action, threadId: threadId, base: base)
        } catch is URLError {
            // The sidecar restarted on another port: look it up again and retry once.
            knownSidecarBase = nil
            try await threadAction(action, threadId: threadId, base: sidecarBase(tabManager: tabManager))
        } catch NewChatError.sidecarUnavailable {
            // Another lookup was in flight; it's done in a moment.
            try await Task.sleep(for: .milliseconds(600))
            try await threadAction(action, threadId: threadId, base: sidecarBase(tabManager: tabManager))
        }
    }

    private func threadAction(_ action: ThreadAction, threadId: String, base: String?) async throws {
        guard let base,
              let encoded = threadId.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))),
              let endpoint = URL(string: "\(base)api/t3/threads/\(encoded)/\(action.rawValue)")
        else { throw NewChatError.sidecarUnavailable }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw NewChatError.rejected(body?["error"] as? String ?? String(localized: "agentHome.t3.actionFailed", defaultValue: "T3 didn't take the change."))
        }
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
        let project = allProjects.first { $0.id == projectId }
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
