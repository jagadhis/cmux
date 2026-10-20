import AppKit
import CmuxAgentHome
import SwiftUI

/// The files a session wrote, working memory first, then plans, then
/// everything else. Unlike the Changes card's git status, this includes files
/// outside the project, such as the notes an agent keeps in `work-memory/`.
///
/// A file written in the last couple of minutes is marked, so a note being
/// updated stands out while the agent works.
struct AgentHomeSessionFilesCard<Accessory: View>: View {
    let title: String
    let files: [AgentSessionFile]
    /// The session's folder; paths inside it show relative to it.
    let root: String?
    let emptyText: String
    let onOpen: (AgentSessionFile) -> Void
    let accessory: Accessory

    @State private var expandedKinds: Set<AgentSessionFile.Kind> = []

    private static var collapsedLimit: Int { 6 }

    init(
        title: String,
        files: [AgentSessionFile],
        root: String?,
        emptyText: String,
        onOpen: @escaping (AgentSessionFile) -> Void,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.files = files
        self.root = root
        self.emptyText = emptyText
        self.onOpen = onOpen
        self.accessory = accessory()
    }

    var body: some View {
        let groups = Dictionary(grouping: files, by: \.kind)
        let kinds = AgentSessionFile.Kind.allCases.filter { groups[$0]?.isEmpty == false }
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                AgentHomeSectionHeader(title: title, detail: files.isEmpty ? nil : "\(files.count)")
                Spacer(minLength: 6)
                accessory
            }
            VStack(alignment: .leading, spacing: 0) {
                if files.isEmpty {
                    Text(emptyText)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // Re-render every 30 s so "just updated" marks and times fade.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(kinds, id: \.self) { kind in
                                section(kind, files: groups[kind] ?? [], now: context.date)
                                if kind != kinds.last { Divider().opacity(0.5) }
                            }
                        }
                    }
                }
            }
            .agentHomeCard()
        }
    }

    @ViewBuilder
    private func section(_ kind: AgentSessionFile.Kind, files: [AgentSessionFile], now: Date) -> some View {
        let isExpanded = expandedKinds.contains(kind)
        let shown = isExpanded ? files : Array(files.prefix(Self.collapsedLimit))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(for: kind))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Self.tint(for: kind))
                Text(Self.label(for: kind))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: "\(files.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 3)
            ForEach(shown) { file in
                AgentHomeSessionFileRow(file: file, root: root, now: now, onOpen: { onOpen(file) })
            }
            if files.count > Self.collapsedLimit {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if isExpanded { expandedKinds.remove(kind) } else { expandedKinds.insert(kind) }
                    }
                } label: {
                    Text(isExpanded
                        ? String(localized: "agentHome.sessionFiles.showFewer", defaultValue: "Show fewer")
                        : String(localized: "agentHome.sessionFiles.showMore", defaultValue: "Show \(files.count - Self.collapsedLimit) more"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .padding(.bottom, 5)
    }

    static func symbol(for kind: AgentSessionFile.Kind) -> String {
        switch kind {
        case .workingMemory: return "brain"
        case .plan: return "list.bullet.clipboard"
        case .file: return "doc.text"
        }
    }

    static func tint(for kind: AgentSessionFile.Kind) -> Color {
        switch kind {
        case .workingMemory: return Color(red: 0.62, green: 0.45, blue: 0.95)
        case .plan: return AgentHomePalette.needsYou
        case .file: return .secondary
        }
    }

    static func label(for kind: AgentSessionFile.Kind) -> String {
        switch kind {
        case .workingMemory: return String(localized: "agentHome.sessionFiles.workingMemory", defaultValue: "Working memory")
        case .plan: return String(localized: "agentHome.sessionFiles.plans", defaultValue: "Plans")
        case .file: return String(localized: "agentHome.sessionFiles.files", defaultValue: "Files")
        }
    }
}

extension AgentHomeSessionFilesCard where Accessory == EmptyView {
    init(
        title: String,
        files: [AgentSessionFile],
        root: String?,
        emptyText: String,
        onOpen: @escaping (AgentSessionFile) -> Void
    ) {
        self.init(title: title, files: files, root: root, emptyText: emptyText, onOpen: onOpen) { EmptyView() }
    }
}

private struct AgentHomeSessionFileRow: View {
    let file: AgentSessionFile
    let root: String?
    let now: Date
    let onOpen: () -> Void

    @State private var isHovered = false

    /// Written within this long ago counts as just updated.
    private static var recentInterval: TimeInterval { 120 }

    var body: some View {
        let display = file.displayPath(relativeTo: root)
        let slash = display.lastIndex(of: "/")
        let directory = slash.map { String(display[...$0]) } ?? ""
        let name = slash.map { String(display[display.index(after: $0)...]) } ?? display
        let isRecent = file.lastEditedAt.map { now.timeIntervalSince($0) < Self.recentInterval } ?? false
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Circle()
                    .fill(AgentHomePalette.running)
                    .frame(width: 5, height: 5)
                    .opacity(isRecent ? 1 : 0)
                    .help(String(localized: "agentHome.sessionFiles.justUpdated", defaultValue: "Updated in the last two minutes"))
                (Text(directory).foregroundStyle(.tertiary) + Text(name).foregroundStyle(.primary))
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 6)
                if file.editCount > 1 {
                    Text(verbatim: "×\(file.editCount)")
                        .foregroundStyle(.tertiary)
                        .help(String(localized: "agentHome.sessionFiles.editCount", defaultValue: "Written \(file.editCount) times"))
                }
                if let edited = file.lastEditedAt {
                    Text(AgentHomeFormat.relative(edited, now: now))
                        .foregroundStyle(isRecent ? AgentHomePalette.running : Color.secondary)
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(isHovered ? 0.04 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(file.path)
        .contextMenu {
            Button(String(localized: "agentHome.sessionFiles.open", defaultValue: "Open in cmux"), action: onOpen)
            Button(String(localized: "agentHome.sessionFiles.reveal", defaultValue: "Reveal in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            }
            Button(String(localized: "agentHome.sessionFiles.copyPath", defaultValue: "Copy Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
        }
    }
}

/// Opens a session's file inside its task's workspace, in the viewer cmux
/// picks for the file type (Markdown, file preview, …).
@MainActor
enum AgentHomeSessionFileOpener {
    static func open(_ path: String, inWorkspace workspaceId: UUID, tabManager: TabManager) {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
              // The last pane: the terminal beside a T3 chat, so the chat stays visible.
              let pane = workspace.bonsplitController.allPaneIds.last ?? workspace.bonsplitController.focusedPaneId
        else { return }
        AgentHomeTaskViewState.shared.setMode(.sessions, for: workspaceId)
        _ = workspace.openFileSurfaces(inPane: pane, filePaths: [path], focus: true, reuseExisting: true)
    }
}
