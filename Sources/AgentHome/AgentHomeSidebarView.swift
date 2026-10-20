import CmuxAgentHome
import SwiftUI

/// The Agent Home left sidebar: the Needs you / Running / Ready for review
/// views, then projects with their tasks.
///
/// Clicking a view jumps to the next task in it, cycling from the selected task.
struct AgentHomeSidebarView: View {
    @ObservedObject var tabManager: TabManager

    /// Projects whose T3 tasks are all shown, keyed by group id or T3 project id.
    @State private var expandedT3Lists: Set<String> = []

    private let t3Model = AgentHomeT3Model.shared
    private static let collapsedT3Count = 3

    var body: some View {
        let snapshot = AgentHomeSnapshotBuilder.snapshot(tabManager: tabManager, feed: AgentHomeFeedModel.shared.signals())
        let t3 = t3Model.sections(tabManager: tabManager)
        let shortcutNumbers = Dictionary(
            uniqueKeysWithValues: snapshot.listedTasks.prefix(9).enumerated().map { ($1.id, $0 + 1) }
        )
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(AgentHomeFilter.allCases, id: \.self) { filter in
                    AgentHomeFilterRow(filter: filter, count: snapshot.count(of: filter)) {
                        jump(to: filter, in: snapshot)
                    }
                }

                if !snapshot.projects.isEmpty {
                    AgentHomeSectionLabel(
                        title: String(localized: "agentHome.sidebar.projects", defaultValue: "Projects")
                    )
                    ForEach(snapshot.projects) { project in
                        AgentHomeProjectRow(
                            project: project,
                            isSelected: project.home.map { $0.id == tabManager.selectedTabId } ?? false
                        ) {
                            if let home = project.home { tabManager.focusTab(home.id) }
                        }
                        ForEach(project.tasks) { task in
                            taskRow(task, indented: true, shortcut: shortcutNumbers[task.id])
                        }
                        t3Rows(t3.byGroup[project.id] ?? [], listKey: project.id.uuidString, indented: true)
                    }
                }

                if !snapshot.ungroupedTasks.isEmpty {
                    AgentHomeSectionLabel(
                        title: snapshot.projects.isEmpty
                            ? String(localized: "agentHome.sidebar.tasks", defaultValue: "Tasks")
                            : String(localized: "agentHome.sidebar.otherTasks", defaultValue: "Other tasks")
                    )
                    ForEach(snapshot.ungroupedTasks) { task in
                        taskRow(task, indented: false, shortcut: shortcutNumbers[task.id])
                    }
                }

                if !t3.t3OnlyProjects.isEmpty {
                    AgentHomeSectionLabel(
                        title: String(localized: "agentHome.sidebar.fromT3", defaultValue: "From T3 Code")
                    )
                    ForEach(t3.t3OnlyProjects) { project in
                        AgentHomeT3ProjectRow(name: project.name, taskCount: project.tasks.count)
                        t3Rows(project.tasks, listKey: project.id, indented: true)
                    }
                }

                if t3.unsortedCount > 0 {
                    AgentHomeT3UnsortedRow(count: t3.unsortedCount)
                        .padding(.top, 10)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
        .onAppear { t3Model.startIfNeeded() }
    }

    @ViewBuilder
    private func t3Rows(_ proposals: [T3TaskProposal], listKey: String, indented: Bool) -> some View {
        let isExpanded = expandedT3Lists.contains(listKey)
        let visible = isExpanded ? proposals : Array(proposals.prefix(Self.collapsedT3Count))
        ForEach(visible) { proposal in
            AgentHomeT3TaskRow(proposal: proposal, indented: indented) {
                t3Model.open(proposal, tabManager: tabManager)
            }
        }
        if proposals.count > Self.collapsedT3Count {
            AgentHomeT3MoreRow(
                hiddenCount: proposals.count - Self.collapsedT3Count,
                isExpanded: isExpanded,
                indented: indented
            ) {
                withAnimation(.easeOut(duration: 0.18)) {
                    if isExpanded { expandedT3Lists.remove(listKey) } else { expandedT3Lists.insert(listKey) }
                }
            }
        }
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

    /// Selects the next task in a view after the selected one, wrapping around.
    private func jump(to filter: AgentHomeFilter, in snapshot: AgentHomeSnapshot) {
        let matches = snapshot.tasks(matching: filter)
        guard !matches.isEmpty else { return }
        let currentIndex = matches.firstIndex { $0.id == tabManager.selectedTabId }
        let next = currentIndex.map { matches[(matches.index(after: $0)) % matches.count] } ?? matches[0]
        tabManager.focusTab(next.id)
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                AgentHomeProjectBadge(name: project.input.name, colorHex: project.input.colorHex)
                Text(project.input.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let home = project.home, home.status == .needsYou || home.status == .running {
                    AgentHomeStatusDot(status: home.status)
                } else if !project.tasks.isEmpty {
                    Text(project.tasks.count, format: .number)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .agentHomeRowChrome(isSelected: isSelected)
        }
        .buttonStyle(AgentHomeRowButtonStyle())
        .disabled(project.home == nil)
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
