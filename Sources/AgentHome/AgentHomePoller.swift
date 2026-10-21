import Foundation

/// Runs a refresh on an interval while something on screen needs it and cmux
/// is the active app.
///
/// Views that show the data hold the poller (``hold()`` / ``release()``,
/// usually through `agentHomePolling(_:isEnabled:)`); with no holders, or
/// while the app is inactive, nothing runs. Coming back refreshes as soon as
/// a full interval has passed since the last run, so switching apps often
/// doesn't turn a two-minute poll into one per switch.
@MainActor
final class AgentHomePoller {
    /// What to run on each tick. The model owning the poller sets it, capturing itself weakly.
    var action: (@MainActor @Sendable () async -> Void)?

    private let interval: Duration
    private var holders = 0
    private var loop: Task<Void, Never>?
    private var lastRun: ContinuousClock.Instant?
    private var activityObserver: UUID?

    init(interval: Duration) {
        self.interval = interval
    }

    /// Something on screen needs fresh data.
    func hold() {
        holders += 1
        update()
    }

    /// A holder went away.
    func release() {
        holders = max(holders - 1, 0)
        update()
    }

    private func update() {
        let activity = AgentHomeAppActivity.shared
        if holders > 0, activityObserver == nil {
            activityObserver = activity.addObserver { [weak self] _ in self?.update() }
        } else if holders == 0, let activityObserver {
            activity.removeObserver(activityObserver)
            self.activityObserver = nil
        }
        let shouldRun = holders > 0 && activity.isActive
        if shouldRun, loop == nil {
            let interval = interval
            let wait = lastRun.map { interval - (ContinuousClock.now - $0) } ?? .zero
            loop = Task { [weak self] in
                if wait > .zero { try? await Task.sleep(for: wait) }
                while !Task.isCancelled {
                    self?.lastRun = .now
                    // A refresh in flight finishes even if polling stops, so a
                    // half-done read never reports a cancellation as an error.
                    if let action = self?.action { await Task { await action() }.value }
                    try? await Task.sleep(for: interval)
                }
            }
        } else if !shouldRun, let loop {
            loop.cancel()
            self.loop = nil
        }
    }
}
