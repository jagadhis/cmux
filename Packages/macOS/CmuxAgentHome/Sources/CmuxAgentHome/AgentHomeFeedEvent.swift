import Foundation

/// One Feed item, as the Agent Home fold reads it.
///
/// The app maps each Feed item that reaches a terminal to an event, keyed by
/// that terminal, and hands the events to ``AgentHomeFeedFold``.
///
/// ```swift
/// let event = AgentHomeFeedEvent(
///     terminalKey: panelId.uuidString.uppercased(),
///     createdAt: item.createdAt,
///     updatedAt: item.updatedAt,
///     workingDirectory: item.cwd,
///     payload: .toolUse(toolName: "Read", toolInputJSON: json)
/// )
/// ```
public struct AgentHomeFeedEvent: Sendable {
    /// What happened.
    public enum Payload: Sendable {
        /// The agent asked to run a tool.
        ///
        /// - `isPending`: whether the request still waits on an answer.
        /// - `canAlwaysAllow`: whether "Always allow" applies to it.
        case permissionRequest(requestId: String, toolName: String, toolInputJSON: String?, isPending: Bool, canAlwaysAllow: Bool)
        /// The agent called a tool.
        case toolUse(toolName: String, toolInputJSON: String?)
        /// The agent replaced its plan.
        case plan([AgentHomePlanStep])
        /// The user sent a prompt.
        case userPrompt(String)
        /// The agent replied.
        case assistantMessage(String)
        /// The agent stopped, with its final message if any.
        case stop(reason: String?)
        /// The session ended.
        case sessionEnd
        /// A new session started in the terminal.
        case sessionStart
        /// Anything the fold doesn't read, which still counts as activity.
        case other
    }

    /// The terminal the event belongs to, such as an uppercased panel id.
    public var terminalKey: String
    /// When the event arrived.
    public var createdAt: Date
    /// When the event last changed, such as a permission request being answered.
    public var updatedAt: Date
    /// The agent's working directory, for showing file paths relative to it.
    public var workingDirectory: String?
    /// What happened.
    public var payload: Payload

    /// Creates an event.
    ///
    /// - Parameters:
    ///   - terminalKey: The terminal the event belongs to.
    ///   - createdAt: When the event arrived.
    ///   - updatedAt: When the event last changed.
    ///   - workingDirectory: The agent's working directory.
    ///   - payload: What happened.
    public init(terminalKey: String, createdAt: Date, updatedAt: Date, workingDirectory: String? = nil, payload: Payload) {
        self.terminalKey = terminalKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.workingDirectory = workingDirectory
        self.payload = payload
    }
}
