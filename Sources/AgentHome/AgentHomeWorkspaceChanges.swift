import Combine
import SwiftUI

/// Re-renders Agent Home when workspaces change in ways its views can't
/// observe on their own.
///
/// A workspace's title, group, folder and tab titles are `@Published` on an
/// `ObservableObject` nobody in Agent Home observes, and its agents'
/// lifecycle states are kept outside Observation. This listens to those
/// (never to terminal input or output) and bumps `token` at most every
/// 100 ms, so the snapshot built in `body` catches up without rebuilding on
/// every event in a burst.
private struct AgentHomeWorkspaceChangesModifier: ViewModifier {
    let workspaces: [Workspace]
    @Binding var token: Int

    private static let debounce: Duration = .milliseconds(100)

    func body(content: Content) -> some View {
        content.task(id: workspaces.map(\.id)) {
            for await _ in Self.changes(of: workspaces) {
                // Let the rest of a burst land, then render once.
                try? await Task.sleep(for: Self.debounce)
                guard !Task.isCancelled else { return }
                token &+= 1
            }
        }
    }

    /// One event per change, newest only, across `workspaces`.
    @MainActor
    private static func changes(of workspaces: [Workspace]) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let lifecycle = workspaces.flatMap { workspace in
                [
                    Task { @MainActor in
                        for await _ in workspace.sidebarAgentRuntimeObservation.changes() { continuation.yield() }
                    },
                    // Process titles change many times a second while an agent
                    // animates its terminal title; this settled stream doesn't.
                    Task { @MainActor in
                        for await _ in workspace.sidebarProcessTitleObservation.changes() { continuation.yield() }
                    },
                ]
            }
            let published = workspaces.flatMap { workspace -> [AnyCancellable] in
                [
                    // Committed renames only; automatic process-title writes come through the settled stream above.
                    workspace.sidebarTitleDidChangePublisher.dropFirst().sink { _ in continuation.yield() },
                    workspace.$groupId.dropFirst().sink { _ in continuation.yield() },
                    workspace.$currentDirectory.dropFirst().sink { _ in continuation.yield() },
                    workspace.$panelCustomTitles.dropFirst().sink { _ in continuation.yield() },
                ]
            }
            // Holds the subscriptions until the stream ends; touched only from onTermination.
            nonisolated(unsafe) let subscriptions = published
            continuation.onTermination = { _ in
                lifecycle.forEach { $0.cancel() }
                subscriptions.forEach { $0.cancel() }
            }
        }
    }
}

extension View {
    /// Bumps `token` shortly after any of `workspaces` changes; read `token` in `body` to re-render.
    func agentHomeWatchesWorkspaces(_ workspaces: [Workspace], token: Binding<Int>) -> some View {
        modifier(AgentHomeWorkspaceChangesModifier(workspaces: workspaces, token: token))
    }
}
