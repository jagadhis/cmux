import CmuxAgentHome
import Foundation
import Observation

/// T3 Code tasks for Agent Home: read from T3's database (read-only), grouped
/// into tasks by project and branch, and opened as cmux tasks on demand.
@MainActor
@Observable
final class AgentHomeT3Model {
    static let shared = AgentHomeT3Model()

    /// T3 tasks placed in the sidebar.
    struct Sections: Equatable {
        /// Unopened T3 tasks under an existing cmux project, by workspace group id.
        var byGroup: [UUID: [T3TaskProposal]] = [:]
        /// T3 projects with no cmux project yet, most recently active first.
        var t3OnlyProjects: [T3OnlyProject] = []
        /// Threads that aren't in any task.
        var unsortedCount = 0
    }

    struct T3OnlyProject: Equatable, Identifiable {
        var id: String
        var name: String
        var tasks: [T3TaskProposal]
    }

    private(set) var grouping: T3ThreadGroupingResult?
    private var links: [String: UUID]
    private var refreshTask: Task<Void, Never>?

    private static let linksDefaultsKey = "agentHomeT3TaskLinks"
    private static let refreshInterval: Duration = .seconds(60)

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.linksDefaultsKey) as? [String: String] ?? [:]
        links = stored.compactMapValues(UUID.init(uuidString:))
    }

    /// Starts reading T3's database every minute. Safe to call repeatedly.
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
        let result = await Task.detached(priority: .utility) { () -> T3ThreadGroupingResult? in
            let reader = T3CodeStateReader()
            guard FileManager.default.fileExists(atPath: reader.databaseURL.path),
                  let threads = try? reader.activeThreads()
            else { return nil }
            let scratch = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/scratch").path
            return T3ThreadGrouping.group(threads, scratchDirectory: scratch)
        }.value
        if result != grouping { grouping = result }
    }

    /// Places T3 tasks that aren't open yet under their cmux projects.
    func sections(tabManager: TabManager) -> Sections {
        guard let grouping else { return Sections() }
        let groups = linkGroups(tabManager: tabManager)
        let workspaces = linkWorkspaces(tabManager: tabManager)
        var sections = Sections(unsortedCount: grouping.unsorted.count)
        var t3Only: [String: T3OnlyProject] = [:]
        var t3OnlyOrder: [String] = []

        for proposal in grouping.tasks {
            let groupId = groupId(for: proposal, groups: groups)
            let isOpen = T3Linking.openWorkspaceId(
                for: proposal,
                linkedWorkspaceId: links[proposal.id],
                groupId: groupId,
                in: workspaces
            ) != nil
            guard !isOpen else { continue }
            if let groupId {
                sections.byGroup[groupId, default: []].append(proposal)
            } else {
                if t3Only[proposal.projectId] == nil {
                    t3OnlyOrder.append(proposal.projectId)
                    t3Only[proposal.projectId] = T3OnlyProject(id: proposal.projectId, name: proposal.projectName, tasks: [])
                }
                t3Only[proposal.projectId]?.tasks.append(proposal)
            }
        }
        sections.t3OnlyProjects = t3OnlyOrder.compactMap { t3Only[$0] }
        return sections
    }

    /// Opens a T3 task as a cmux task: in its project (created when missing),
    /// in its worktree, then selects it. An already-open task is just selected.
    func open(_ proposal: T3TaskProposal, tabManager: TabManager) {
        let groups = linkGroups(tabManager: tabManager)
        var groupId = groupId(for: proposal, groups: groups)
        if let existing = T3Linking.openWorkspaceId(
            for: proposal,
            linkedWorkspaceId: links[proposal.id],
            groupId: groupId,
            in: linkWorkspaces(tabManager: tabManager)
        ) {
            tabManager.focusTab(existing)
            return
        }
        if groupId == nil {
            groupId = tabManager.createWorkspaceGroup(
                name: proposal.projectName,
                anchorWorkingDirectory: proposal.projectRoot,
                selectAnchor: false,
                collapseSidebarSelection: false,
                externalID: T3Linking.externalID(forProjectId: proposal.projectId)
            )
        }
        let workspace = tabManager.addWorkspace(
            title: proposal.title,
            workingDirectory: T3Linking.directory(for: proposal),
            select: true
        )
        if let groupId {
            tabManager.addWorkspaceToGroup(workspaceId: workspace.id, groupId: groupId)
        }
        // Filing into a group can move selection back; land on the new task.
        tabManager.focusTab(workspace.id)
        links[proposal.id] = workspace.id
        UserDefaults.standard.set(links.mapValues(\.uuidString), forKey: Self.linksDefaultsKey)
    }

    private func groupId(for proposal: T3TaskProposal, groups: [T3LinkGroup]) -> UUID? {
        T3Linking.groupId(
            forProjectId: proposal.projectId,
            projectName: proposal.projectName,
            projectRoot: proposal.projectRoot,
            in: groups
        )
    }

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

    private func linkWorkspaces(tabManager: TabManager) -> [T3LinkWorkspace] {
        tabManager.tabs.map {
            T3LinkWorkspace(id: $0.id, title: $0.title, groupId: $0.groupId, directory: $0.currentDirectory)
        }
    }
}
