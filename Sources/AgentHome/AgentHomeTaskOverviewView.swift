import AppKit
import CMUXAgentLaunch
import CmuxAgentHome
import CmuxGit
import CmuxWorkspaces
import SwiftUI

// MARK: - Overview

struct AgentHomeTaskOverview: View {
    let task: AgentHomeTask
    let actions: AgentHomeOverviewActions

    /// `nil` until the first read, so the card doesn't flash "No uncommitted changes".
    @State private var changedFiles: [AgentHomeChangedFile]?

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(alignment: .top, spacing: 22) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        AgentHomeSectionHeader(
                            title: String(localized: "agentHome.overview.agents", defaultValue: "Agents"),
                            detail: task.input.agents.isEmpty ? nil : "\(task.input.agents.count)"
                        )
                        if task.input.agents.isEmpty {
                            AgentHomeEmptyAgents()
                        } else {
                            ForEach(task.input.agents) { agent in
                                AgentHomeAgentCard(
                                    agent: agent,
                                    onReply: actions.reply,
                                    onOpenTerminal: { actions.openTerminal(agent) }
                                )
                            }
                        }
                    }
                    .padding(.bottom, 90)
                }
                .scrollIndicators(.never)

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 18) {
                        if let pr = task.input.pullRequest {
                            AgentHomePullRequestCard(pullRequest: pr, branch: task.input.branch)
                        }
                        AgentHomeSessionFilesCard(
                            title: String(localized: "agentHome.sessionFiles.sessionsTitle", defaultValue: "Written this session"),
                            files: AgentSessionFile.merged(task.input.agents.map(\.editedFiles)),
                            root: task.input.directory,
                            emptyText: String(localized: "agentHome.sessionFiles.agentsEmpty", defaultValue: "Files and working-memory notes the agents edit show up here."),
                            onOpen: { actions.openFile($0.path) }
                        )
                        AgentHomeChangesCard(files: changedFiles)
                    }
                    .padding(.bottom, 90)
                }
                .scrollIndicators(.never)
                .frame(width: 270)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)

            AgentHomeComposer(agents: task.input.agents, onSend: actions.send)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .agentHomePageBackground()
        .task(id: ChangesLoad(directory: task.input.directory, isAppActive: AgentHomeAppActivity.shared.isActive)) {
            await loadChanges()
        }
    }

    /// What the changes read depends on: the folder, and whether cmux is active
    /// (reads stop while it isn't, and refresh as soon as it's back).
    private struct ChangesLoad: Equatable {
        var directory: String?
        var isAppActive: Bool
    }

    /// Loads the working tree's changes, then refreshes every 10 s while the
    /// overview is open and cmux is active.
    private func loadChanges() async {
        guard let directory = task.input.directory else {
            changedFiles = []
            return
        }
        guard AgentHomeAppActivity.shared.isActive else { return }
        let service = WorkspaceChangesService()
        while !Task.isCancelled {
            if let result = try? await service.changedFiles(forDirectory: directory) {
                changedFiles = result.files.map {
                    AgentHomeChangedFile(path: $0.path, additions: $0.additions, deletions: $0.deletions)
                }
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }
}

struct AgentHomeSectionHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(spacing: 7) {
            Text(title).fontWeight(.semibold).foregroundStyle(.tertiary)
            if let detail { Text(detail).foregroundStyle(.secondary) }
        }
        .font(.system(size: 11.5))
    }
}

private struct AgentHomeEmptyAgents: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "agentHome.overview.noAgents.title", defaultValue: "No agents in this task yet"))
                .font(.system(size: 13, weight: .medium))
            Text(String(localized: "agentHome.overview.noAgents.body", defaultValue: "Start Claude, Codex or OpenCode in one of its terminals and it shows up here with its plan and live activity."))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .agentHomeCard()
    }
}

// MARK: - Side column

private struct AgentHomePullRequestCard: View {
    let pullRequest: AgentHomePullRequest
    let branch: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AgentHomeSectionHeader(title: String(localized: "agentHome.overview.pullRequest", defaultValue: "Pull request"))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "#\(pullRequest.number) \(pullRequest.title)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(2)
                Text(stateText + (branch.map { " · \($0)" } ?? ""))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !pullRequest.checks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(pullRequest.checks, id: \.name) { check in
                            HStack(spacing: 8) {
                                Circle().fill(color(for: check.outcome)).frame(width: 6, height: 6)
                                Text(check.name).font(.system(size: 12))
                            }
                        }
                    }
                    .padding(.top, 7)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .agentHomeCard()
            .onTapGesture { if let url = pullRequest.url { NSWorkspace.shared.open(url) } }
        }
    }

    private var stateText: String {
        switch pullRequest.state {
        case .open: return String(localized: "agentHome.pr.open", defaultValue: "Open")
        case .merged: return String(localized: "agentHome.pr.merged", defaultValue: "Merged")
        case .closed: return String(localized: "agentHome.pr.closed", defaultValue: "Closed")
        }
    }

    private func color(for outcome: AgentHomePullRequest.Check.Outcome) -> Color {
        switch outcome {
        case .passed: return AgentHomePalette.done
        case .pending: return AgentHomePalette.needsYou
        case .failed: return .red
        }
    }
}

private struct AgentHomeChangesCard: View {
    /// The changed files, or `nil` while they're first being read.
    let files: [AgentHomeChangedFile]?

    var body: some View {
        let isLoading = self.files == nil
        let files = self.files ?? []
        let additions = files.reduce(0) { $0 + $1.additions }
        let deletions = files.reduce(0) { $0 + $1.deletions }
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                AgentHomeSectionHeader(title: String(localized: "agentHome.overview.changes", defaultValue: "Changes"))
                if !files.isEmpty {
                    Text(verbatim: "+\(additions)").foregroundStyle(AgentHomePalette.done)
                    Text(verbatim: "−\(deletions)").foregroundStyle(.red.opacity(0.8))
                }
            }
            .font(.system(size: 11.5).monospacedDigit())
            VStack(alignment: .leading, spacing: 0) {
                if files.isEmpty {
                    Text(String(localized: "agentHome.overview.noChanges", defaultValue: "No uncommitted changes"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                        .opacity(isLoading ? 0 : 1)
                } else {
                    ForEach(files.prefix(12), id: \.path) { file in
                        AgentHomeFileRow(file: file)
                    }
                    if files.count > 12 {
                        Text(String(localized: "agentHome.overview.moreFiles", defaultValue: "\(files.count - 12) more files"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 5)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .agentHomeCard()
        }
    }
}

private struct AgentHomeFileRow: View {
    let file: AgentHomeChangedFile

    var body: some View {
        HStack(spacing: 8) {
            (Text(file.directory).foregroundStyle(.tertiary) + Text(file.fileName))
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 6)
            Text(verbatim: "+\(file.additions)").foregroundStyle(AgentHomePalette.done)
            Text(verbatim: "−\(file.deletions)").foregroundStyle(.red.opacity(0.8))
            AgentHomeDiffBar(additions: file.additions, deletions: file.deletions)
        }
        .font(.system(size: 11).monospacedDigit())
        .padding(.vertical, 5)
    }
}

private struct AgentHomeDiffBar: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        let total = max(additions + deletions, 1)
        let added = Int((Double(additions) / Double(total) * 5).rounded())
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < added ? AgentHomePalette.done : (deletions > 0 ? Color.red.opacity(0.75) : Color.primary.opacity(0.12)))
                    .frame(width: 4, height: 7)
            }
        }
    }
}

// MARK: - Composer

private struct AgentHomeComposer: View {
    let agents: [AgentHomeAgent]
    let onSend: (AgentHomeAgent, String) -> Void

    @State private var text = ""
    @State private var targetId: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        let target = agents.first { $0.id == targetId } ?? agents.first { $0.state != .idle } ?? agents.first
        HStack(spacing: 10) {
            TextField(
                agents.isEmpty
                    ? String(localized: "agentHome.composer.noAgents", defaultValue: "Start an agent in this task to message it")
                    : String(localized: "agentHome.composer.placeholder", defaultValue: "Tell the agents what to do next…"),
                text: $text
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($isFocused)
            .disabled(agents.isEmpty)
            .onSubmit { send(to: target) }

            if let target {
                Menu {
                    ForEach(agents) { agent in
                        Button(agent.title) { targetId = agent.id }
                    }
                } label: {
                    Text(target.title).lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 12))
            }

            Button { send(to: target) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(text.isEmpty ? Color.primary.opacity(0.12) : Color.primary))
                    .foregroundStyle(text.isEmpty ? Color.secondary : Color(nsColor: .windowBackgroundColor))
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || target == nil)
        }
        .padding(.leading, 14)
        .padding(.trailing, 9)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isFocused ? AgentHomePalette.running.opacity(0.55) : Color.primary.opacity(0.1), lineWidth: isFocused ? 1 : 0.5)
        )
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    private func send(to target: AgentHomeAgent?) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target, !message.isEmpty else { return }
        onSend(target, message)
        text = ""
    }
}
