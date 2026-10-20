import CmuxAgentHome
import SwiftUI

/// Starts a new T3 thread: pick a project, say what the agent should do.
/// T3 runs it with the project's usual model and names the thread.
struct AgentHomeNewChatSheet: View {
    let projects: [T3ProjectNode]
    let preselectedProjectId: String?
    let onStart: (_ projectId: String, _ text: String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var projectId = ""
    @State private var text = ""
    @State private var isStarting = false
    @State private var errorMessage: String?
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(String(localized: "agentHome.newChat.title", defaultValue: "New chat"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Picker("", selection: $projectId) {
                    ForEach(projects) { project in
                        Text(project.name).tag(project.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help(String(localized: "agentHome.newChat.project", defaultValue: "Project"))
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(String(localized: "agentHome.newChat.placeholder", defaultValue: "What should the agent do?"))
                        .font(.system(size: 13.5))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.system(size: 13.5))
                    .scrollContentBackground(.hidden)
                    .focused($isEditorFocused)
                    .disabled(isStarting)
            }
            .frame(minHeight: 110)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text(String(localized: "agentHome.newChat.hint", defaultValue: "Runs in T3 · syncs both ways"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(String(localized: "agentHome.newChat.cancel", defaultValue: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    start()
                } label: {
                    if isStarting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(String(localized: "agentHome.newChat.start", defaultValue: "Start"))
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(isStarting || projectId.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            projectId = preselectedProjectId.flatMap { id in projects.contains { $0.id == id } ? id : nil }
                ?? projects.first?.id ?? ""
            isEditorFocused = true
        }
    }

    private func start() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !projectId.isEmpty else { return }
        isStarting = true
        errorMessage = nil
        Task {
            do {
                try await onStart(projectId, message)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isStarting = false
            }
        }
    }
}
