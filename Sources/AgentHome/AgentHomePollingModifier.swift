import SwiftUI

/// Holds Agent Home pollers while the view is on screen and `isEnabled`.
private struct AgentHomePollingModifier: ViewModifier {
    /// Looked up only while enabled, so an inactive Agent Home never creates its models.
    let pollers: @MainActor () -> [AgentHomePoller]
    let isEnabled: Bool

    @State private var held: [AgentHomePoller] = []

    func body(content: Content) -> some View {
        content
            .onAppear { setHolding(isEnabled) }
            .onDisappear { setHolding(false) }
            .onChange(of: isEnabled) { _, enabled in setHolding(enabled) }
    }

    private func setHolding(_ holding: Bool) {
        if holding, held.isEmpty {
            held = pollers()
            held.forEach { $0.hold() }
        } else if !holding, !held.isEmpty {
            held.forEach { $0.release() }
            held = []
        }
    }
}

extension View {
    /// Keeps `pollers` running while this view is on screen and `isEnabled`.
    func agentHomePolling(isEnabled: Bool = true, _ pollers: @escaping @MainActor () -> [AgentHomePoller]) -> some View {
        modifier(AgentHomePollingModifier(pollers: pollers, isEnabled: isEnabled))
    }
}
