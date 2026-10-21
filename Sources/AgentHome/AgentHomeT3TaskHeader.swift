import CmuxAgentHome
import SwiftUI

/// The header for a T3 task: project › task (› the thread a sub-thread is under › sub-thread),
/// Chat / Overview, and the sync badge.
struct AgentHomeT3TaskHeader: View {
    let task: T3TaskNode
    let projectName: String?
    let shownSubThread: T3Thread?
    let mode: AgentHomeTaskViewState.Mode
    let onModeChange: (AgentHomeTaskViewState.Mode) -> Void
    let onOpenRoot: () -> Void
    let onOpenThread: (T3Thread) -> Void
    let onVerify: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let projectName, !projectName.isEmpty {
                Text(projectName).foregroundStyle(.tertiary)
                Text(verbatim: "›").foregroundStyle(.tertiary)
            }
            if let shownSubThread {
                Button(action: onOpenRoot) {
                    Text(task.thread.title).foregroundStyle(.secondary).lineLimit(1)
                }
                .buttonStyle(.plain)
                .help(String(localized: "agentHome.t3.backToMain", defaultValue: "Back to the main thread"))
                Text(verbatim: "›").foregroundStyle(.tertiary)
                let parent = task.listedParent(of: shownSubThread)
                if parent.id != task.thread.id {
                    Button { onOpenThread(parent) } label: {
                        Text(parent.title).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "agentHome.t3.backToParent", defaultValue: "Open the thread that started this one"))
                    Text(verbatim: "›").foregroundStyle(.tertiary)
                }
                Text(shownSubThread.title).fontWeight(.semibold).lineLimit(1)
            } else {
                Text(task.thread.title).fontWeight(.semibold).lineLimit(1)
            }
            if let branch = task.thread.branch {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10.5))
                    Text(branch).font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
                }
                .foregroundStyle(.tertiary)
                .padding(.leading, 6)
            }
            Spacer(minLength: 12)
            Picker("", selection: Binding(get: { mode }, set: onModeChange)) {
                Text(String(localized: "agentHome.mode.chat", defaultValue: "Chat"))
                    .tag(AgentHomeTaskViewState.Mode.sessions)
                Text(task.allThreads.count == 1
                    ? String(localized: "agentHome.mode.overview", defaultValue: "Overview")
                    : String(localized: "agentHome.mode.overviewCount", defaultValue: "Overview · \(task.allThreads.count)"))
                    .tag(AgentHomeTaskViewState.Mode.overview)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            AgentHomeT3StatusBar(task: task, onVerify: onVerify)
                .animation(.easeOut(duration: 0.2), value: task.status)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 18)
        .frame(height: 48)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }
}
