import Foundation

/// What the Feed knows about one agent terminal, for its Agent Home card.
public struct AgentHomeFeedSignals: Equatable, Sendable {
    /// The permission request waiting on the user, if any.
    public var pendingPermission: AgentHomePermissionRequest?
    /// The "doing now" line, while the agent works.
    public var currentActivity: String?
    /// The agent's latest plan.
    public var plan: [AgentHomePlanStep] = []
    /// A summary of the agent's latest reply.
    public var lastSummary: String?
    /// The current session's first prompt, as a card title.
    public var sessionTitle: String?
    /// When the current session's first event arrived.
    public var startedAt: Date?
    /// When the current session last changed.
    public var lastActivityAt: Date?
    /// The files the current session wrote, working-memory notes included.
    public var editedFiles = AgentSessionFileLog()

    /// Creates empty signals, optionally with the session's times.
    ///
    /// - Parameters:
    ///   - startedAt: When the session started.
    ///   - lastActivityAt: When the session last changed.
    public init(startedAt: Date? = nil, lastActivityAt: Date? = nil) {
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
    }
}
