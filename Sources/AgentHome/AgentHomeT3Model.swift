import AppKit
import CmuxAgentHome
import Combine
import Foundation
import Observation

/// T3 Code threads in Agent Home.
///
/// T3 runs the agents. This model reads T3's local database (read-only) every
/// few seconds into a project → task → sub-thread tree, and opens a task as a
/// cmux workspace: the thread's chat (the agent-chat sidecar's T3 view) on the
/// left and a terminal in the task's folder on the right. Sub-threads, and the
/// threads an agent handed work off to, open in the same workspace's chat.
///
/// A thread link in a chat (`t3-thread://`) navigates the chat with `via=link`;
/// the model follows it into the thread's own task when it belongs to another.
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
    /// The threads the last verify settled, for undo.
    private var lastVerifiedThreadIds: [String] = []
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
    /// New chat panes waiting for T3 to start their thread, by workspace id.
    private var newChatWatchers: [UUID: AnyCancellable] = [:]
    private var refreshTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    /// Which thread launched which (handoffs), saved between launches because
    /// the first read of T3's history takes seconds.
    private var launchIndex: T3LaunchIndex
    private var isScanningLaunches = false
    /// Watches each T3 workspace's chat for thread links, by workspace id.
    private var chatWatchers: [UUID: (panel: ObjectIdentifier, cancellable: AnyCancellable)] = [:]
    /// The chat panel Agent Home added to each workspace, by workspace id.
    private var chatPanelIds: [UUID: UUID] = [:]

    private static let linksDefaultsKey = "agentHomeT3TaskWorkspaces"
    private static let refreshInterval: Duration = .seconds(3)

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.linksDefaultsKey) as? [String: String] ?? [:]
        taskLinks = stored.compactMapValues(UUID.init(uuidString:))
        launchIndex = (try? Data(contentsOf: Self.launchIndexURL)).flatMap { try? JSONDecoder().decode(T3LaunchIndex.self, from: $0) } ?? T3LaunchIndex()
    }

    private static var launchIndexURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundle = Bundle.main.bundleIdentifier ?? "cmux"
        return support.appendingPathComponent(bundle).appendingPathComponent("agent-home-t3-launches.json")
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
        newChatWatchers = newChatWatchers.filter { id, _ in tabManager?.tabs.contains { $0.id == id } == true }
        let openTaskIds = Set(taskLinks.compactMap { id, workspace in
            tabManager?.tabs.contains { $0.id == workspace } == true ? id : nil
        })
        // An open task's handoffs stay readable after they're settled, like its sub-threads.
        let openMainThreadIds = Set(allTasks.filter { openTaskIds.contains($0.id) }.flatMap { $0.mainThreads.map(\.id) })
        let index = launchIndex
        let read = await Task.detached(priority: .utility) { () -> ([T3ProjectNode], [T3CodeStateReader.Project], T3LaunchIndex)? in
            let reader = T3CodeStateReader()
            guard FileManager.default.fileExists(atPath: reader.databaseURL.path) else { return nil }
            var index = index
            // New launches since the last read take milliseconds; a full read of the history runs separately.
            if index.hasScanned { try? reader.updateLaunchIndex(&index, allowsFullRead: false) }
            guard let threads = Self.readThreads(reader, openTaskIds: openTaskIds, index: index, includingThreadIds: openMainThreadIds)
            else { return nil }
            return (T3ThreadTree.build(threads), (try? reader.projects()) ?? [], index)
        }.value
        guard let (built, all, updatedIndex) = read else { return }
        if updatedIndex.isAhead(of: launchIndex) { setLaunchIndex(updatedIndex) }
        if !launchIndex.hasScanned { scanLaunchHistory() }
        if all != allProjects { allProjects = all }
        readProjects = built
        relinkRegroupedTasks(built)
        // Stop hiding a verified task once T3 shows it settled or no longer lists it.
        let listed = Dictionary(built.flatMap { $0.recentTasks + $0.olderTasks }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        verifying = verifying.filter { listed[$0].map { !Self.isSettled($0) } ?? false }
        publish()
        if let tabManager { watchChats(tabManager: tabManager) }
    }

    /// A task opened on its own can become a handoff in another task once its
    /// launch is known. Its workspace then belongs to that task.
    private func relinkRegroupedTasks(_ projects: [T3ProjectNode]) {
        let tasks = projects.flatMap { $0.recentTasks + $0.olderTasks }
        let roots = Set(tasks.map(\.id))
        var changed = false
        for (threadId, workspaceId) in taskLinks where !roots.contains(threadId) {
            guard let task = tasks.first(where: { $0.thread(withId: threadId) != nil }), taskLinks[task.id] == nil else { continue }
            taskLinks[threadId] = nil
            taskLinks[task.id] = workspaceId
            changed = true
        }
        if changed { UserDefaults.standard.set(taskLinks.mapValues(\.uuidString), forKey: Self.linksDefaultsKey) }
    }

    /// Reads the listed threads with their launchers, plus the settled threads
    /// they were handed off from, so a handoff stays under the thread that started it.
    nonisolated private static func readThreads(
        _ reader: T3CodeStateReader,
        openTaskIds: Set<String>,
        index: T3LaunchIndex,
        includingThreadIds: Set<String> = []
    ) -> [T3Thread]? {
        guard var threads = try? reader.activeThreads(openTaskIds: openTaskIds, includingThreadIds: includingThreadIds) else { return nil }
        threads = index.applied(to: threads)
        let missing = T3ThreadTree.missingLaunchers(of: threads, index: index)
        if !missing.isEmpty,
           let more = try? reader.activeThreads(openTaskIds: openTaskIds, includingThreadIds: includingThreadIds.union(missing)) {
            threads = index.applied(to: more)
        }
        return threads
    }

    /// Reads every thread launch in T3's history once, in the background, then regroups.
    private func scanLaunchHistory() {
        guard !isScanningLaunches else { return }
        isScanningLaunches = true
        let index = launchIndex
        Task {
            let scanned = await Task.detached(priority: .utility) { () -> T3LaunchIndex? in
                var index = index
                return (try? T3CodeStateReader().updateLaunchIndex(&index)) == nil ? nil : index
            }.value
            isScanningLaunches = false
            guard let scanned, scanned.isAhead(of: launchIndex) else { return }
            setLaunchIndex(scanned)
            await reload()
        }
    }

    private func setLaunchIndex(_ index: T3LaunchIndex) {
        launchIndex = index
        let url = Self.launchIndexURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(index) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Whether every thread the user verifies in a task is settled.
    private static func isSettled(_ task: T3TaskNode) -> Bool {
        task.mainThreads.allSatisfy(\.isSettled)
    }

    /// Publishes the tree, without tasks being verified or settled tasks that are no longer open.
    private func publish() {
        let visible = readProjects.compactMap { project -> T3ProjectNode? in
            var project = project
            let keep = { (task: T3TaskNode) in
                !self.verifying.contains(task.id) && (!Self.isSettled(task) || self.taskLinks[task.id] != nil)
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
        return allTasks.first { $0.id == taskId } ?? allTasks.first { $0.thread(withId: taskId) != nil }
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

    /// Any listed thread, in any task.
    func thread(withId id: String) -> T3Thread? {
        for task in allTasks {
            if let thread = task.thread(withId: id) { return thread }
        }
        return nil
    }

    // MARK: - Opening

    /// Opens a task, or one of its handoffs or sub-threads, as a cmux task:
    /// creates the workspace on first open, then shows the thread in its chat.
    func open(_ task: T3TaskNode, thread: T3Thread? = nil, tabManager: TabManager) {
        AgentHomeTaskViewState.shared.page = nil
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
            file(workspace.id, in: project, tabManager: tabManager)
        }
        tabManager.focusTab(workspace.id)
        link(task.id, toWorkspace: workspace.id, showing: target.id)

        let workspaceId = workspace.id
        Task {
            await self.addChat(toWorkspace: workspaceId, threadId: target.id, tabManager: tabManager)
            self.watchChats(tabManager: tabManager)
        }
    }

    /// A project for a task that isn't in the tree yet (a thread started moments ago).
    private func projectStub(for task: T3TaskNode) -> T3ProjectNode? {
        guard let name = task.thread.projectName else { return nil }
        return T3ProjectNode(id: task.thread.projectId, name: name, root: task.thread.projectRoot, recentTasks: [], olderTasks: [])
    }

    /// Files a workspace under the project's cmux project, creating it if it's missing.
    private func file(_ workspaceId: UUID, in project: T3ProjectNode, tabManager: TabManager) {
        let groupId = groupId(for: project, tabManager: tabManager) ?? (project.id.isEmpty ? nil : tabManager.createWorkspaceGroup(
            name: project.name,
            anchorWorkingDirectory: project.root,
            selectAnchor: false,
            collapseSidebarSelection: false,
            externalID: T3Linking.externalID(forProjectId: project.id)
        ))
        if let groupId { tabManager.addWorkspaceToGroup(workspaceId: workspaceId, groupId: groupId) }
    }

    /// Records that a workspace holds a task and which of its threads the chat shows.
    private func link(_ taskId: String, toWorkspace workspaceId: UUID, showing threadId: String) {
        taskLinks[taskId] = workspaceId
        shownThreadIds[workspaceId] = threadId
        UserDefaults.standard.set(taskLinks.mapValues(\.uuidString), forKey: Self.linksDefaultsKey)
    }

    /// Puts the thread's chat to the left of the workspace's terminal.
    private func addChat(toWorkspace workspaceId: UUID, threadId: String, tabManager: TabManager) async {
        guard let url = await chatURL(threadId: threadId, workspaceId: workspaceId, tabManager: tabManager),
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
              let terminalId = workspace.focusedPanelId ?? workspace.panels.keys.first
        else { NSSound.beep(); return }
        let chat = workspace.newBrowserSplit(
            from: terminalId,
            orientation: .horizontal,
            insertFirst: true,
            url: url,
            focus: true,
            chromeVisibility: .hidden,
            transparentBackground: true,
            initialDividerPosition: 0.62
        )
        chatPanelIds[workspaceId] = chat?.id
    }

    /// Points the workspace's chat at another thread in its task.
    private func navigateChat(inWorkspace workspaceId: UUID, toThread threadId: String, tabManager: TabManager) async {
        guard let url = await chatURL(threadId: threadId, workspaceId: workspaceId, tabManager: tabManager),
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceId })
        else { return }
        if let chat = chatPanel(in: workspace) {
            _ = chat.navigate(to: url)
        } else {
            await addChat(toWorkspace: workspaceId, threadId: threadId, tabManager: tabManager)
        }
    }

    /// `<sidecar>/t3/<thread id>?transparent=1&workspace=<id>`, starting the sidecar if needed.
    /// The chat sends the workspace back when it asks cmux to open a link beside it.
    private func chatURL(threadId: String, workspaceId: UUID? = nil, tabManager: TabManager) async -> URL? {
        guard let base = await sidecarBase(tabManager: tabManager),
              let encoded = threadId.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_")))
        else { return nil }
        let workspace = workspaceId.map { "&workspace=\($0.uuidString)" } ?? ""
        return URL(string: "\(base)t3/\(encoded)?transparent=1\(workspace)")
    }

    /// The workspace's chat: the browser showing the sidecar's T3 view. A pull
    /// request opened beside the task is a browser too, so it's told apart by URL.
    func chatPanel(in workspace: Workspace) -> BrowserPanel? {
        if let id = chatPanelIds[workspace.id], let chat = workspace.panels[id] as? BrowserPanel { return chat }
        let browsers = workspace.panels.values.compactMap { $0 as? BrowserPanel }
        return browsers.first { T3ChatLinks.isChatURL($0.currentURL) } ?? (browsers.count == 1 ? browsers.first : nil)
    }

    // MARK: - Thread links in chats

    /// Watches each open T3 task's chat for thread links (`t3-thread://` in a
    /// message), which navigate the chat to `/t3/<id>?via=link`.
    private func watchChats(tabManager: TabManager) {
        for (_, workspaceId) in taskLinks {
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
                  let chat = chatPanel(in: workspace)
            else {
                chatWatchers[workspaceId] = nil
                continue
            }
            if chatWatchers[workspaceId]?.panel == ObjectIdentifier(chat) { continue }
            let cancellable = chat.$currentURL
                .compactMap { $0 }
                .removeDuplicates()
                .sink { [weak self, weak tabManager] url in
                    guard let self, let tabManager else { return }
                    Task { @MainActor in self.chatDidNavigate(to: url, inWorkspace: workspaceId, tabManager: tabManager) }
                }
            chatWatchers[workspaceId] = (ObjectIdentifier(chat), cancellable)
        }
    }

    /// A chat followed a thread link: show the thread in this task when it's
    /// part of it, otherwise put the chat back and open the thread's own task.
    private func chatDidNavigate(to url: URL, inWorkspace workspaceId: UUID, tabManager: TabManager) {
        guard let threadId = T3ChatLinks.linkedThreadId(in: url), shownThreadIds[workspaceId] != threadId else { return }
        if let task = task(forWorkspace: workspaceId), let thread = task.thread(withId: threadId) {
            shownThreadIds[workspaceId] = threadId
            if thread.hasUnseenResult { markSeen(threadId, tabManager: tabManager) }
            return
        }
        let previous = shownThreadIds[workspaceId] ?? task(forWorkspace: workspaceId)?.thread.id
        if let previous {
            Task { await navigateChat(inWorkspace: workspaceId, toThread: previous, tabManager: tabManager) }
        }
        openThread(id: threadId, tabManager: tabManager)
    }

    /// Opens any T3 thread in its task, reading it from T3 when it isn't listed.
    func openThread(id threadId: String, tabManager: TabManager) {
        if let task = allTasks.first(where: { $0.thread(withId: threadId) != nil }) {
            let thread = task.thread(withId: threadId)
            open(task, thread: thread == task.thread ? nil : thread, tabManager: tabManager)
            return
        }
        let index = launchIndex
        Task {
            let task = await Task.detached(priority: .userInitiated) { () -> T3TaskNode? in
                let threads = Self.readThreads(T3CodeStateReader(), openTaskIds: [threadId], index: index, includingThreadIds: [threadId]) ?? []
                return T3ThreadTree.build(threads).flatMap { $0.recentTasks + $0.olderTasks }.first { $0.thread(withId: threadId) != nil }
            }.value
            guard let task else { NSSound.beep(); return }
            let thread = task.thread(withId: threadId)
            open(task, thread: thread == task.thread ? nil : thread, tabManager: tabManager)
        }
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
            let thread = threadId.flatMap(task.thread(withId:))
            open(task, thread: thread == task.thread ? nil : thread, tabManager: tabManager)
        }
        // The task may be part of another task's handoff chain by now.
        if let task = allTasks.first(where: { $0.id == taskId || $0.thread(withId: taskId) != nil }) { return show(task) }
        let index = launchIndex
        Task {
            let task = await Task.detached(priority: .userInitiated) { () -> T3TaskNode? in
                let threads = Self.readThreads(T3CodeStateReader(), openTaskIds: [taskId], index: index) ?? []
                return T3ThreadTree.build(threads).flatMap { $0.recentTasks + $0.olderTasks }.first { $0.thread(withId: taskId) != nil }
            }.value
            if let task { show(task) } else { NSSound.beep() }
        }
    }

    // MARK: - Reviewing

    /// Tasks whose agents finished and that wait for the user to verify them, in sidebar order.
    var tasksToVerify: [T3TaskNode] { allTasks.filter { $0.status == .done } }

    /// Marks a task verified: settles it in T3 (like T3's Settle), with every
    /// thread it handed off to, opens the next task waiting for review if this
    /// one was on screen, and closes its workspace. Undo puts it back with
    /// ``undoVerify(tabManager:)``.
    func verify(_ task: T3TaskNode, tabManager: TabManager) {
        // The next row slides under the pointer when a task leaves the list;
        // a quick second click shouldn't verify it too.
        guard Date().timeIntervalSince(lastVerifyAt) > 0.8 else { return }
        lastVerifyAt = Date()
        let workspaceId = workspaceId(forTask: task.id, tabManager: tabManager)
        let wasOnScreen = workspaceId != nil && workspaceId == tabManager.selectedTabId
        let next = tasksToVerify.first { $0.id != task.id }

        // Settling the main thread settles its sub-threads; handoffs are threads of their own.
        let threadIds = task.mainThreads.filter { !$0.isSettled }.map(\.id)
        verifying.insert(task.id)
        publish()
        showToast(verified: task)
        lastVerifiedThreadIds = threadIds
        if wasOnScreen, let next { open(next, tabManager: tabManager) }
        if let workspaceId, let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
           tabManager.closeWorkspaceWithConfirmation(workspace) {
            taskLinks[task.id] = nil
            shownThreadIds[workspaceId] = nil
            chatWatchers[workspaceId] = nil
            chatPanelIds[workspaceId] = nil
            UserDefaults.standard.set(taskLinks.mapValues(\.uuidString), forKey: Self.linksDefaultsKey)
        }

        Task {
            do {
                for threadId in threadIds {
                    try await threadAction(.settle, threadId: threadId, tabManager: tabManager)
                }
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
        let threadIds = lastVerifiedThreadIds
        lastVerified = nil
        lastVerifiedThreadIds = []
        verifying.remove(task.id)
        Task {
            do {
                for threadId in threadIds {
                    try await threadAction(.unsettle, threadId: threadId, tabManager: tabManager)
                }
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

    /// Reads a sidecar API path such as `api/t3/usage?…`, looking the sidecar up again once if it moved.
    func sidecarGET(_ path: String, tabManager: TabManager) async throws -> (Data, Int) {
        func get(_ base: String?) async throws -> (Data, Int) {
            guard let base, let url = URL(string: base + path) else { throw NewChatError.sidecarUnavailable }
            let (data, response) = try await URLSession.shared.data(from: url)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        do {
            let base: String? = if let knownSidecarBase { knownSidecarBase } else { await sidecarBase(tabManager: tabManager) }
            return try await get(base)
        } catch is URLError {
            knownSidecarBase = nil
            return try await get(sidecarBase(tabManager: tabManager))
        } catch NewChatError.sidecarUnavailable {
            // Another lookup was in flight; it's done in a moment.
            try await Task.sleep(for: .milliseconds(600))
            return try await get(sidecarBase(tabManager: tabManager))
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

    /// Opens a New chat pane: a task in the project whose chat is a composer
    /// for a new T3 thread, with the same model, reasoning and access controls
    /// as a T3 chat. Once T3 starts the thread, the pane becomes that task and
    /// a terminal opens beside it, as for any opened T3 task.
    ///
    /// - Parameters:
    ///   - projectId: The T3 project to start in; the user can pick another.
    ///   - text: Text to put in the composer, like a review prompt.
    func openNewChat(projectId: String?, text: String = "", tabManager: TabManager) {
        AgentHomeTaskViewState.shared.page = nil
        Task { await addNewChat(projectId: projectId, text: text, tabManager: tabManager) }
    }

    private func addNewChat(projectId: String?, text: String, tabManager: TabManager) async {
        guard let base = await sidecarBase(tabManager: tabManager), var components = URLComponents(string: "\(base)t3/new") else {
            showToast(error: NewChatError.sidecarUnavailable.errorDescription)
            return
        }
        components.queryItems = [URLQueryItem(name: "transparent", value: "1")]
            + (projectId.map { [URLQueryItem(name: "project", value: $0)] } ?? [])
            + (text.isEmpty ? [] : [URLQueryItem(name: "text", value: text)])
        guard let url = components.url else { return }

        let project = allProjects.first { $0.id == projectId }
        guard let workspace = tabManager.addWorkspaceIfActive(
            title: String(localized: "agentHome.newChat.title", defaultValue: "New chat"),
            workingDirectory: project?.root,
            initialSurface: .browser,
            initialBrowserURL: url,
            initialBrowserOmnibarVisible: false,
            initialBrowserTransparentBackground: true,
            select: true
        ) else { return }
        if let project {
            file(workspace.id, in: T3ProjectNode(id: project.id, name: project.name, root: project.root, recentTasks: [], olderTasks: []), tabManager: tabManager)
        }
        tabManager.focusTab(workspace.id)
        guard let chat = workspace.panels.values.compactMap({ $0 as? BrowserPanel }).first else { return }

        // The page moves to the thread's chat URL once T3 has started it.
        let workspaceId = workspace.id
        let chatId = chat.id
        newChatWatchers[workspaceId] = chat.$currentURL
            .compactMap { $0.flatMap(T3Linking.threadId(fromChatURL:)) }
            .first()
            .sink { [weak self, weak tabManager] threadId in
                guard let self, let tabManager else { return }
                newChatWatchers[workspaceId] = nil
                Task { await self.linkNewChat(workspaceId: workspaceId, chatId: chatId, threadId: threadId, tabManager: tabManager) }
            }
    }

    /// Turns a New chat pane into the task T3 just started: links it, names it,
    /// files it under the thread's project and opens the terminal beside the chat.
    private func linkNewChat(workspaceId: UUID, chatId: UUID, threadId: String, tabManager: TabManager) async {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
        link(threadId, toWorkspace: workspaceId, showing: threadId)
        chatPanelIds[workspaceId] = chatId
        let thread = await startedThread(threadId)
        if let thread {
            _ = workspace.setCustomTitle(thread.title)
            if let project = projectStub(for: T3TaskNode(thread: thread)) {
                file(workspaceId, in: project, tabManager: tabManager)
            }
        }
        if workspace.panels[chatId] != nil, workspace.panels.count == 1 {
            _ = workspace.newTerminalSplit(
                from: chatId,
                orientation: .horizontal,
                focus: false,
                workingDirectory: thread.flatMap { $0.worktreePath ?? $0.projectRoot },
                initialDividerPosition: 0.62
            )
        }
        await reload()
    }

    /// Reads a thread T3 has just started. T3 writes it to its database a
    /// moment after accepting it, so this tries for a couple of seconds.
    private func startedThread(_ threadId: String) async -> T3Thread? {
        for attempt in 0..<6 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(400)) }
            let thread = await Task.detached(priority: .userInitiated) {
                (try? T3CodeStateReader().activeThreads(openTaskIds: [threadId]))?.first { $0.id == threadId }
            }.value
            if let thread { return thread }
        }
        return nil
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
