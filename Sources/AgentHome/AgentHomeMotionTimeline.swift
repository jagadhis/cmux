import SwiftUI

/// Drives Agent Home's always-on motion (activity bars, the running dot, the
/// shimmer on a live activity line, plan spinners) from one low-rate clock.
///
/// It ticks at most six times a second, stops while the window isn't active
/// (the app in the background included), and hands content `nil` under
/// Reduce Motion so it draws still.
struct AgentHomeMotionTimeline<Content: View>: View {
    /// Draws one frame from the time in seconds, or `nil` to draw still.
    @ViewBuilder let content: (TimeInterval?) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    static var frameInterval: TimeInterval { 1.0 / 6.0 }

    var body: some View {
        TimelineView(.animation(minimumInterval: Self.frameInterval, paused: reduceMotion || activeState == .inactive)) { context in
            content(reduceMotion ? nil : context.date.timeIntervalSinceReferenceDate)
        }
    }
}
