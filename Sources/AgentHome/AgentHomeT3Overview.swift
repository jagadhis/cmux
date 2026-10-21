import CmuxAgentHome
import SwiftUI

/// A T3 task at a glance: every session (the main thread, the threads it
/// handed off to, the sub-threads its agents created) and how the thread on
/// screen relates to them, beside the pull requests the task linked.
struct AgentHomeT3Overview: View {
    let task: T3TaskNode
    let shownThreadId: String?
    let workspaceId: UUID
    @ObservedObject var tabManager: TabManager
    let onOpen: (T3Thread) -> Void
    let onOpenThread: (String) -> Void
    let onStartChat: (String) -> Void

    @State private var filesScope: FilesScope = .session

    private let t3Model = AgentHomeT3Model.shared
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    enum FilesScope: Hashable { case session, task }

    var body: some View {
        // Each main thread, followed by the sub-threads under it, so a sub-agent sits next to the thread that started it.
        let outline = task.subThreadOutline()
        let parents = Dictionary(
            task.mainThreads.flatMap { outline.rows(under: $0.id) }.map { ($0.id, $0.parent?.title ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        let sessions = task.mainThreads.flatMap { [$0] + outline.rows(under: $0.id).map(\.thread) }
        let live = sessions.filter { T3ThreadStatus.of($0) < .done }.count
        let shown = task.thread(withId: shownThreadId ?? task.thread.id) ?? task.thread
        let filesByThread = t3Model.sessionFilesByThread
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 7) {
                            Text(String(localized: "agentHome.t3.sessionsInTask", defaultValue: "Sessions in this task"))
                                .fontWeight(.semibold).foregroundStyle(.tertiary)
                            Text(live > 0
                                ? String(localized: "agentHome.t3.sessionsLive", defaultValue: "\(sessions.count) · \(live) live")
                                : "\(sessions.count)")
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11.5))
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(sessions, id: \.id) { thread in
                                AgentHomeT3SessionCard(
                                    thread: thread,
                                    role: role(of: thread),
                                    parentTitle: parents[thread.id],
                                    isShown: thread.id == shown.id,
                                    files: filesByThread[thread.id] ?? []
                                ) { onOpen(thread) }
                            }
                        }
                    }
                    sessionFiles(shown: shown, sessionCount: sessions.count, filesByThread: filesByThread)
                    AgentHomeT3RelationshipsCard(
                        thread: shown,
                        task: task,
                        title: { id in task.thread(withId: id)?.title ?? t3Model.thread(withId: id)?.title },
                        onOpen: onOpenThread
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                AgentHomeT3LinkedPullRequests(
                    task: task,
                    workspaceId: workspaceId,
                    tabManager: tabManager,
                    onStartChat: onStartChat,
                    onOpenThread: onOpenThread
                )
                .frame(width: 330)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .agentHomePageBackground()
        .task(id: FilesLoad(threadIds: sessions.map(\.id), isAppActive: AgentHomeAppActivity.shared.isActive)) {
            await loadFiles(threadIds: sessions.map(\.id))
        }
    }

    /// The files the shown thread wrote, or every session in the task.
    @ViewBuilder
    private func sessionFiles(shown: T3Thread, sessionCount: Int, filesByThread: [String: [AgentSessionFile]]) -> some View {
        let isTask = filesScope == .task && sessionCount > 1
        // `nil` until the first read, so the card doesn't flash "Nothing written yet".
        let files: [AgentSessionFile]? = isTask
            ? (filesByThread[task.thread.id] == nil ? nil : AgentSessionFile.merged(task.allThreads.map { filesByThread[$0.id] ?? [] }))
            : filesByThread[shown.id]
        let root = isTask ? (task.thread.worktreePath ?? task.thread.projectRoot) : (shown.worktreePath ?? shown.projectRoot)
        AgentHomeSessionFilesCard(
            title: isTask
                ? String(localized: "agentHome.sessionFiles.taskTitle", defaultValue: "Files this task wrote")
                : String(localized: "agentHome.sessionFiles.sessionTitle", defaultValue: "Files this session wrote"),
            files: files,
            root: root,
            emptyText: String(localized: "agentHome.sessionFiles.empty", defaultValue: "Nothing written yet. Files and working-memory notes the agent edits show up here as it works."),
            onOpen: { file in AgentHomeSessionFileOpener.open(file.path, inWorkspace: workspaceId, tabManager: tabManager) }
        ) {
            if sessionCount > 1 {
                Picker("", selection: $filesScope) {
                    Text(String(localized: "agentHome.sessionFiles.scope.session", defaultValue: "This session")).tag(FilesScope.session)
                    Text(String(localized: "agentHome.sessionFiles.scope.task", defaultValue: "Whole task")).tag(FilesScope.task)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    /// What the files read depends on: the sessions shown, and whether cmux is
    /// active (reads stop while it isn't, and refresh as soon as it's back).
    private struct FilesLoad: Equatable {
        var threadIds: [String]
        var isAppActive: Bool
    }

    /// Reads the files each session wrote, then again every few seconds while
    /// the overview is open and cmux is active.
    private func loadFiles(threadIds: [String]) async {
        guard AgentHomeAppActivity.shared.isActive else { return }
        while !Task.isCancelled {
            let read = await Task.detached(priority: .utility) {
                try? T3CodeStateReader().sessionFiles(threadIds: threadIds)
            }.value
            if let read { t3Model.setSessionFiles(read, forThreads: threadIds) }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func role(of thread: T3Thread) -> AgentHomeT3SessionCard.Role {
        if thread.id == task.thread.id { return .main }
        return task.handoffs.contains { $0.id == thread.id } ? .handoff : .subThread
    }
}

private struct AgentHomeT3SessionCard: View {
    enum Role { case main, handoff, subThread }

    let thread: T3Thread
    let role: Role
    /// The thread that started this one, for a sub-thread.
    var parentTitle: String?
    let isShown: Bool
    /// The files the session wrote.
    var files: [AgentSessionFile] = []
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        let status = T3ThreadStatus.of(thread)
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    AgentHomeAgentAvatar(kind: kind, contextFraction: nil)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(thread.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                        if status == .running, let progress = thread.subagent?.progress {
                            Text(progress).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    if status == .done {
                        AgentHomeT3StatusDot(status: status, unseen: thread.hasUnseenResult, endedEarly: thread.latestRunEndedEarly)
                    } else {
                        AgentHomeStatePill(state: status == .needsYou ? .needsYou : status == .running ? .running : .idle)
                    }
                }
                if !files.isEmpty { filesSummary }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .agentHomeCard(
                highlight: status == .needsYou ? AgentHomePalette.needsYou : (isShown ? AgentHomePalette.running : nil),
                hovered: isHovered
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
        .opacity(status >= .done && role == .subThread ? 0.75 : 1)
    }

    private var kind: AgentHomeAgentKind { thread.agentKind }

    /// "2 memory notes · 5 files", with the latest working-memory note it wrote.
    private var filesSummary: some View {
        let memory = files.filter { $0.kind == .workingMemory }
        let others = files.count - memory.count
        return HStack(spacing: 5) {
            if let latest = memory.first {
                Image(systemName: "brain").foregroundStyle(AgentHomePalette.purple)
                Text(memory.count == 1
                    ? String(localized: "agentHome.sessionFiles.oneMemoryNote", defaultValue: "1 memory note")
                    : String(localized: "agentHome.sessionFiles.memoryNotes", defaultValue: "\(memory.count) memory notes"))
                Text(verbatim: "·").foregroundStyle(.tertiary)
                Text((latest.path as NSString).lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(latest.path)
            }
            if others > 0 {
                if !memory.isEmpty { Text(verbatim: "·").foregroundStyle(.tertiary) }
                Image(systemName: "doc.text")
                Text(others == 1
                    ? String(localized: "agentHome.sessionFiles.oneFile", defaultValue: "1 file")
                    : String(localized: "agentHome.sessionFiles.fileCount", defaultValue: "\(others) files"))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.leading, 40)
    }

    private var subtitle: String {
        var parts: [String] = switch role {
        case .main: [String(localized: "agentHome.t3.mainThread", defaultValue: "Main thread")]
        case .handoff: [String(localized: "agentHome.t3.handoffThread", defaultValue: "Handoff")]
        case .subThread:
            switch (thread.relationshipToParent, parentTitle) {
            case ("subagent", let parent?): [String(localized: "agentHome.t3.subAgentOf", defaultValue: "Sub-agent of \(parent)")]
            case ("fork", let parent?): [String(localized: "agentHome.t3.forkOf", defaultValue: "Forked from \(parent)")]
            case (_, let parent?): [String(localized: "agentHome.t3.subThreadOf", defaultValue: "Sub-thread of \(parent)")]
            case (_, nil): [String(localized: "agentHome.t3.subThread", defaultValue: "Sub-thread")]
            }
        }
        parts.append(kind.displayName)
        if let updated = thread.updatedAt { parts.append(AgentHomeFormat.relative(updated)) }
        return parts.joined(separator: " · ")
    }
}
