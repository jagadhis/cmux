import CmuxAgentHome
import SwiftUI

/// The Agent Home left sidebar: New chat, the Needs you / Running / Ready for
/// review views, then projects with their tasks. T3 Code threads are tasks
/// too, with the sub-threads their agents created nested under them.
///
/// Clicking a view jumps to the next task in it, cycling from the selected task.
struct AgentHomeSidebarView: View {
    @ObservedObject var tabManager: TabManager

    /// Projects whose T3 tasks are all shown, keyed by group id or T3 project id.
    @State private var expandedT3Lists: Set<String> = []
    @State private var isNewChatPresented = false
    /// Collapsed T3-only projects (cmux projects use the group's own collapsed flag).
    @AppStorage("agentHomeCollapsedT3Projects") private var collapsedT3ProjectsRaw = ""

    private let t3Model = AgentHomeT3Model.shared
    private static let collapsedT3Count = 5
    private static let collapsedSubThreadCount = 6

    var body: some View {
        let snapshot = AgentHomeSnapshotBuilder.snapshot(tabManager: tabManager, feed: AgentHomeFeedModel.shared.signals())
        let layout = t3Layout(snapshot: snapshot)
        let shortcutNumbers = Dictionary(
            uniqueKeysWithValues: snapshot.listedTasks.prefix(9).enumerated().map { ($1.id, $0 + 1) }
        )
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 1) {
                AgentHomeNewChatButton { isNewChatPresented = true }
                    .padding(.bottom, 8)

                ForEach(AgentHomeFilter.allCases, id: \.self) { filter in
                    AgentHomeFilterRow(filter: filter, count: snapshot.count(of: filter) + layout.t3Count(filter)) {
                        jump(to: filter, in: snapshot, layout: layout)
                    }
                }

                if !snapshot.projects.isEmpty || !layout.t3OnlyProjects.isEmpty {
                    AgentHomeSectionLabel(
                        title: String(localized: "agentHome.sidebar.projects", defaultValue: "Projects")
                    )
                    ForEach(snapshot.projects) { project in
                        let isCollapsed = collapsedGroupIds.contains(project.id)
                        let t3Project = layout.t3ByGroup[project.id]
                        AgentHomeProjectRow(
                            project: project,
                            isSelected: project.home.map { $0.id == tabManager.selectedTabId } ?? false,
                            isCollapsed: isCollapsed,
                            hiddenT3Count: t3Project.map { $0.recentTasks.count + $0.olderTasks.count } ?? 0,
                            onOpen: { if let home = project.home { tabManager.focusTab(home.id) } },
                            onToggleCollapsed: {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    tabManager.toggleWorkspaceGroupCollapsed(groupId: project.id)
                                }
                            }
                        )
                        if !isCollapsed {
                            ForEach(project.tasks.filter { !layout.linkedWorkspaceIds.contains($0.id) }) { task in
                                taskRow(task, indented: true, shortcut: shortcutNumbers[task.id])
                            }
                            if let t3Project {
                                t3TaskRows(t3Project, listKey: project.id.uuidString, layout: layout)
                            }
                        }
                    }
                    ForEach(layout.t3OnlyProjects) { project in
                        let isCollapsed = collapsedT3Projects.contains(project.id)
                        AgentHomeT3ProjectRow(
                            name: project.name.isEmpty
                                ? String(localized: "agentHome.sidebar.noProject", defaultValue: "No project")
                                : project.name,
                            taskCount: project.recentTasks.count + project.olderTasks.count,
                            isCollapsed: isCollapsed
                        ) {
                            withAnimation(.easeOut(duration: 0.2)) { toggleT3Project(project.id) }
                        }
                        if !isCollapsed {
                            t3TaskRows(project, listKey: "t3:\(project.id)", layout: layout)
                        }
                    }
                }

                let ungrouped = snapshot.ungroupedTasks.filter { !layout.linkedWorkspaceIds.contains($0.id) }
                if !ungrouped.isEmpty {
                    AgentHomeSectionLabel(
                        title: snapshot.projects.isEmpty && layout.t3OnlyProjects.isEmpty
                            ? String(localized: "agentHome.sidebar.tasks", defaultValue: "Tasks")
                            : String(localized: "agentHome.sidebar.otherTasks", defaultValue: "Other tasks")
                    )
                    ForEach(ungrouped) { task in
                        taskRow(task, indented: false, shortcut: shortcutNumbers[task.id])
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
        .onAppear { t3Model.startIfNeeded() }
        .sheet(isPresented: $isNewChatPresented) {
            AgentHomeNewChatSheet(
                projects: t3Model.projects.filter { !$0.id.isEmpty },
                preselectedProjectId: layout.selectedTask.flatMap { t3Model.project(of: $0)?.id },
                onStart: { projectId, text in
                    try await t3Model.startNewChat(projectId: projectId, text: text, tabManager: tabManager)
                }
            )
        }
    }

    // MARK: - T3 layout

    /// Where T3 projects and tasks go in the sidebar, worked out once per render.
    struct T3Layout {
        var t3ByGroup: [UUID: T3ProjectNode] = [:]
        var t3OnlyProjects: [T3ProjectNode] = []
        var linkedWorkspaceIds: Set<UUID> = []
        var selectedTask: T3TaskNode?
        var shownThreadId: String?
        var allTasks: [T3TaskNode] = []

        func t3Count(_ filter: AgentHomeFilter) -> Int {
            switch filter {
            case .needsYou: return allTasks.filter { $0.status == .needsYou }.count
            case .running: return allTasks.filter { $0.status == .running }.count
            case .readyForReview: return 0
            }
        }
    }

    private func t3Layout(snapshot: AgentHomeSnapshot) -> T3Layout {
        var layout = T3Layout(linkedWorkspaceIds: t3Model.linkedWorkspaceIds)
        let groupIds = Set(snapshot.projects.map(\.id))
        for project in t3Model.projects {
            layout.allTasks += project.recentTasks + project.olderTasks
            if let groupId = t3Model.groupId(for: project, tabManager: tabManager), groupIds.contains(groupId),
               layout.t3ByGroup[groupId] == nil {
                layout.t3ByGroup[groupId] = project
            } else {
                layout.t3OnlyProjects.append(project)
            }
        }
        if let selected = tabManager.selectedTabId {
            layout.selectedTask = t3Model.task(forWorkspace: selected)
            layout.shownThreadId = t3Model.shownThreadIds[selected]
        }
        return layout
    }

    @ViewBuilder
    private func t3TaskRows(_ project: T3ProjectNode, listKey: String, layout: T3Layout) -> some View {
        let isExpanded = expandedT3Lists.contains(listKey)
        let all = project.recentTasks + project.olderTasks
        let visible = isExpanded ? all : Array(project.recentTasks.prefix(Self.collapsedT3Count))
        ForEach(visible) { task in
            let isSelectedTask = layout.selectedTask?.id == task.id
            let shown = isSelectedTask ? (layout.shownThreadId ?? task.thread.id) : nil
            AgentHomeT3TaskRow(task: task, isSelected: shown == task.thread.id) {
                t3Model.open(task, tabManager: tabManager)
            }
            let subThreads = isSelectedTask
                ? Array(task.subThreads.prefix(Self.collapsedSubThreadCount))
                : task.subThreads.filter { T3ThreadStatus.of($0) != .idle }
            ForEach(subThreads, id: \.id) { subThread in
                AgentHomeT3SubThreadRow(thread: subThread, isSelected: shown == subThread.id) {
                    t3Model.open(task, thread: subThread, tabManager: tabManager)
                }
            }
        }
        if all.count > visible.count || isExpanded {
            AgentHomeT3MoreRow(hiddenCount: all.count - visible.count, isExpanded: isExpanded, indented: true) {
                withAnimation(.easeOut(duration: 0.18)) {
                    if isExpanded { expandedT3Lists.remove(listKey) } else { expandedT3Lists.insert(listKey) }
                }
            }
        }
    }

    // MARK: - Helpers

    private var collapsedGroupIds: Set<UUID> {
        Set(tabManager.workspaceGroups.filter(\.isCollapsed).map(\.id))
    }

    private var collapsedT3Projects: Set<String> {
        Set(collapsedT3ProjectsRaw.split(separator: "\n").map(String.init))
    }

    private func toggleT3Project(_ id: String) {
        var ids = collapsedT3Projects
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        collapsedT3ProjectsRaw = ids.sorted().joined(separator: "\n")
    }

    private func taskRow(_ task: AgentHomeTask, indented: Bool, shortcut: Int?) -> some View {
        AgentHomeTaskRow(
            task: task,
            isSelected: tabManager.selectedTabId == task.id,
            indented: indented,
            shortcut: shortcut
        ) {
            tabManager.focusTab(task.id)
        }
    }

    /// Opens the next task in a view after the current one, wrapping around.
    /// cmux tasks come first, then T3 tasks.
    private func jump(to filter: AgentHomeFilter, in snapshot: AgentHomeSnapshot, layout: T3Layout) {
        struct Stop { let key: String; let open: () -> Void }
        var stops = snapshot.tasks(matching: filter).map { task in
            Stop(key: task.id.uuidString) { tabManager.focusTab(task.id) }
        }
        let wanted: T3ThreadStatus? = filter == .needsYou ? .needsYou : filter == .running ? .running : nil
        if let wanted {
            stops += layout.allTasks.filter { $0.status == wanted }.map { task in
                Stop(key: "t3:\(task.id)") { t3Model.open(task, tabManager: tabManager) }
            }
        }
        guard !stops.isEmpty else { return }
        let currentKey = layout.selectedTask.map { "t3:\($0.id)" } ?? tabManager.selectedTabId?.uuidString
        let index = stops.firstIndex { $0.key == currentKey }.map { ($0 + 1) % stops.count } ?? 0
        stops[index].open()
    }
}

// MARK: - Rows

private struct AgentHomeFilterRow: View {
    let filter: AgentHomeFilter
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                Spacer(minLength: 4)
                trailing
            }
            .agentHomeRowChrome(isSelected: false)
        }
        .buttonStyle(AgentHomeRowButtonStyle())
        .disabled(count == 0)
        .help(title)
    }

    @ViewBuilder private var trailing: some View {
        if count > 0 {
            switch filter {
            case .needsYou:
                Text(count, format: .number)
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 17)
                    .background(Capsule().fill(AgentHomePalette.needsYou))
            case .running:
                HStack(spacing: 6) {
                    AgentHomeActivityBars()
                    countText
                }
            case .readyForReview:
                countText
            }
        }
    }

    private var countText: some View {
        Text(count, format: .number)
            .font(.system(size: 11.5).monospacedDigit())
            .foregroundStyle(.tertiary)
    }

    private var title: String {
        switch filter {
        case .needsYou: return String(localized: "agentHome.filter.needsYou", defaultValue: "Needs you")
        case .running: return String(localized: "agentHome.filter.running", defaultValue: "Running")
        case .readyForReview: return String(localized: "agentHome.filter.readyForReview", defaultValue: "Ready for review")
        }
    }

    private var symbol: String {
        switch filter {
        case .needsYou: return "bell"
        case .running: return "bolt"
        case .readyForReview: return "checkmark.circle"
        }
    }
}

private struct AgentHomeProjectRow: View {
    let project: AgentHomeProject
    let isSelected: Bool
    let isCollapsed: Bool
    /// Unopened T3 tasks under this project, counted while it's collapsed.
    let hiddenT3Count: Int
    let onOpen: () -> Void
    let onToggleCollapsed: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 9) {
                    AgentHomeProjectBadge(name: project.input.name, colorHex: project.input.colorHex)
                    Text(project.input.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    trailing
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(AgentHomeRowButtonStyle())
            .disabled(project.home == nil)

            AgentHomeDisclosureChevron(isCollapsed: isCollapsed, action: onToggleCollapsed)
        }
        .agentHomeRowChrome(isSelected: isSelected)
    }

    /// Expanded: the home's live status, else the task count. Collapsed: the
    /// most urgent status in the whole project, so a hidden task that needs
    /// you still shows, else the count of everything folded away.
    @ViewBuilder private var trailing: some View {
        let status = isCollapsed ? project.rollupStatus : project.home?.status
        if let status, status == .needsYou || status == .running {
            AgentHomeStatusDot(status: status)
        } else {
            let count = project.tasks.count + (isCollapsed ? hiddenT3Count : 0)
            if count > 0 {
                Text(count, format: .number)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// The chevron that folds a project or section: up while open, down while folded.
struct AgentHomeDisclosureChevron: View {
    let isCollapsed: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.up")
                .font(.system(size: 9.5, weight: .semibold))
                .rotationEffect(.degrees(isCollapsed ? 180 : 0))
                .foregroundStyle(isHovered ? .secondary : .tertiary)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 4)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.18), value: isCollapsed)
        .help(isCollapsed
            ? String(localized: "agentHome.sidebar.expand", defaultValue: "Show tasks")
            : String(localized: "agentHome.sidebar.collapse", defaultValue: "Hide tasks"))
        .accessibilityLabel(Text(isCollapsed
            ? String(localized: "agentHome.sidebar.expand", defaultValue: "Show tasks")
            : String(localized: "agentHome.sidebar.collapse", defaultValue: "Hide tasks")))
    }
}

/// A section label with a chevron that folds the whole section.
struct AgentHomeCollapsibleSectionLabel: View {
    let title: String
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            AgentHomeDisclosureChevron(isCollapsed: isCollapsed, action: onToggle)
        }
        .padding(.leading, 9)
        .padding(.trailing, 9)
        .padding(.top, 12)
        .padding(.bottom, 1)
    }
}

private struct AgentHomeTaskRow: View {
    let task: AgentHomeTask
    let isSelected: Bool
    let indented: Bool
    let shortcut: Int?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(task.input.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Spacer(minLength: 4)
                if isHovered, let shortcut {
                    Text(verbatim: "⌘\(shortcut)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                        .transition(.opacity)
                } else {
                    AgentHomeStatusDot(status: task.status)
                }
            }
            .padding(.leading, indented ? 24 : 0)
            .agentHomeRowChrome(isSelected: isSelected)
        }
        .buttonStyle(AgentHomeRowButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .accessibilityLabel(Text(task.input.title))
    }
}

private struct AgentHomeSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 9)
            .padding(.top, 16)
            .padding(.bottom, 5)
    }
}

// MARK: - Pieces

/// The small status mark at the end of a task row.
struct AgentHomeStatusDot: View {
    let status: AgentHomeTaskStatus

    var body: some View {
        switch status {
        case .needsYou:
            Circle()
                .fill(AgentHomePalette.needsYou)
                .frame(width: 7, height: 7)
                .background(Circle().fill(AgentHomePalette.needsYou.opacity(0.18)).frame(width: 13, height: 13))
                .frame(width: 14, height: 14)
        case .running:
            AgentHomePulsingDot()
                .frame(width: 14, height: 14)
        case .readyForReview:
            Circle()
                .fill(AgentHomePalette.review)
                .frame(width: 7, height: 7)
                .frame(width: 14, height: 14)
        case .idle, .done:
            Color.clear.frame(width: 14, height: 14)
        }
    }
}

/// A dot that breathes while an agent works.
struct AgentHomePulsingDot: View {
    @State private var expanded = false

    var body: some View {
        ZStack {
            Circle()
                .fill(AgentHomePalette.running.opacity(expanded ? 0 : 0.45))
                .frame(width: expanded ? 15 : 7, height: expanded ? 15 : 7)
            Circle()
                .fill(AgentHomePalette.running)
                .frame(width: 7, height: 7)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { expanded = true }
        }
    }
}

/// Three bars that bounce while any agent is running.
struct AgentHomeActivityBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = (t * 2 * .pi) + Double(index) * 1.2
                    RoundedRectangle(cornerRadius: 1)
                        .fill(AgentHomePalette.running)
                        .frame(width: 2, height: 3 + 7 * (0.5 + 0.5 * sin(phase)))
                }
            }
            .frame(height: 10, alignment: .bottom)
        }
    }
}

/// A rounded square with a project's initial in its colour.
struct AgentHomeProjectBadge: View {
    let name: String
    let colorHex: String?

    var body: some View {
        Text(verbatim: name.first.map { String($0).uppercased() } ?? "•")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(RoundedRectangle(cornerRadius: 4).fill(AgentHomePalette.projectColor(hex: colorHex, name: name)))
    }
}

// MARK: - Styling

enum AgentHomePalette {
    static let needsYou = Color(red: 0.94, green: 0.71, blue: 0.30)
    static let running = Color(red: 0.49, green: 0.55, blue: 1.0)
    static let review = Color(red: 0.49, green: 0.55, blue: 1.0).opacity(0.75)
    static let done = Color(red: 0.37, green: 0.75, blue: 0.55)

    /// Colours for projects without a custom colour, picked stably from the name.
    private static let projectFallbacks: [Color] = [
        Color(red: 0.85, green: 0.45, blue: 0.29),
        Color(red: 0.35, green: 0.42, blue: 0.88),
        Color(red: 0.18, green: 0.62, blue: 0.56),
        Color(red: 0.54, green: 0.44, blue: 0.82),
        Color(red: 0.80, green: 0.36, blue: 0.52),
        Color(red: 0.36, green: 0.55, blue: 0.27),
    ]

    static func projectColor(hex: String?, name: String) -> Color {
        if let hex, let color = color(hex: hex) { return color }
        let index = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % projectFallbacks.count
        return projectFallbacks[index]
    }

    static func color(hex: String) -> Color? {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

private struct AgentHomeRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct AgentHomeRowChrome: ViewModifier {
    let isSelected: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.09 : (isHovered ? 0.05 : 0)))
            )
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

extension View {
    fileprivate func agentHomeRowChrome(isSelected: Bool) -> some View {
        modifier(AgentHomeRowChrome(isSelected: isSelected))
    }
}
