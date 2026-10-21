import AppKit
import Observation

/// Whether cmux is the active app, so Agent Home's polling and animations can
/// rest while the user works elsewhere.
///
/// Views read ``isActive`` from `body` (a `.task(id:)` keyed on it restarts,
/// and refreshes, when the user comes back); pollers subscribe with
/// ``addObserver(_:)``.
@MainActor
@Observable
final class AgentHomeAppActivity {
    static let shared = AgentHomeAppActivity()

    private(set) var isActive: Bool

    @ObservationIgnored private var observers: [UUID: (Bool) -> Void] = [:]
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    private init() {
        isActive = NSApp?.isActive ?? true
        let center = NotificationCenter.default
        tokens = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setActive(true) }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setActive(false) }
            },
        ]
    }

    /// Calls `observer` whenever the app becomes active or inactive.
    ///
    /// - Returns: A token for ``removeObserver(_:)``.
    @discardableResult
    func addObserver(_ observer: @escaping (Bool) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        for observer in observers.values { observer(active) }
    }
}
