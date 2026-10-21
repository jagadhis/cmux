import Foundation

/// Folds Feed events into per-terminal signals for Agent Home's cards.
///
/// Events apply in arrival order: a later plan replaces an earlier one, a
/// permission request stays pending until an answered copy of it arrives, and
/// a new session in the same terminal starts a fresh card.
///
/// Only the last tool call's "doing now" line and the waiting permission
/// request's summary are shown, so they're described once, after the fold,
/// and each tool input is parsed at most once.
///
/// ```swift
/// let signals = AgentHomeFeedFold().signals(for: events)
/// let card = signals[panelId.uuidString.uppercased()]
/// ```
public struct AgentHomeFeedFold: Sendable {
    /// Creates a fold.
    public init() {}

    /// Folds events into signals per terminal.
    ///
    /// - Parameter events: Feed events in any order; they're applied oldest first.
    /// - Returns: Signals keyed by ``AgentHomeFeedEvent/terminalKey``.
    public func signals(for events: [AgentHomeFeedEvent]) -> [String: AgentHomeFeedSignals] {
        // The Feed appends in arrival order, so sorting is usually unnecessary.
        let isChronological = zip(events, events.dropFirst()).allSatisfy { $0.createdAt <= $1.createdAt }
        let ordered = isChronological ? events : events.sorted { $0.createdAt < $1.createdAt }
        var builders: [String: Builder] = [:]
        for event in ordered {
            builders[event.terminalKey, default: Builder()].apply(event)
        }
        return builders.mapValues { $0.finished() }
    }

    /// One terminal's signals while folding, with the lines that need
    /// describing kept raw until the fold is done.
    private struct Builder {
        enum Activity {
            case tool(name: String, json: String?, input: [String: Any]?, workingDirectory: String?)
            case text(String)
        }

        struct Permission {
            var requestId: String
            var toolName: String
            var json: String?
            var workingDirectory: String?
            var canAlwaysAllow: Bool
        }

        var signals = AgentHomeFeedSignals()
        var activity: Activity?
        var permission: Permission?

        mutating func apply(_ event: AgentHomeFeedEvent) {
            signals.startedAt = signals.startedAt ?? event.createdAt
            signals.lastActivityAt = max(signals.lastActivityAt ?? event.updatedAt, event.updatedAt)

            switch event.payload {
            case let .permissionRequest(requestId, toolName, json, isPending, canAlwaysAllow):
                if isPending {
                    permission = Permission(
                        requestId: requestId,
                        toolName: toolName,
                        json: json,
                        workingDirectory: event.workingDirectory,
                        canAlwaysAllow: canAlwaysAllow
                    )
                } else if permission?.requestId == requestId {
                    permission = nil
                }
            case let .toolUse(toolName, json):
                let isPlan = toolName == "TodoWrite"
                let writes = AgentSessionFileLog.mayWrite(toolName: toolName, toolInputJSON: json)
                let parsed: Any? = isPlan || writes ? json?.agentHomeJSONObject : nil
                if isPlan {
                    let steps = AgentHomePlanParser.steps(from: parsed)
                    if !steps.isEmpty { signals.plan = steps }
                }
                if writes {
                    signals.editedFiles.record(
                        toolName: toolName,
                        input: parsed,
                        toolInputJSON: json,
                        workingDirectory: event.workingDirectory,
                        at: event.createdAt
                    )
                }
                activity = .tool(
                    name: toolName,
                    json: json,
                    input: parsed.map { $0 as? [String: Any] ?? [:] },
                    workingDirectory: event.workingDirectory
                )
            case let .plan(steps):
                signals.plan = steps
            case let .userPrompt(text):
                if signals.sessionTitle == nil { signals.sessionTitle = AgentHomeText.title(fromPrompt: text) }
                activity = .text(String(localized: "agentHome.activity.readingPrompt", defaultValue: "Reading your message"))
            case let .assistantMessage(text):
                if let summary = AgentHomeText.summary(fromMarkdown: text) { signals.lastSummary = summary }
            case let .stop(reason):
                activity = nil
                if let reason, let summary = AgentHomeText.summary(fromMarkdown: reason) { signals.lastSummary = summary }
            case .sessionEnd:
                activity = nil
            case .sessionStart:
                // A new session in the same terminal starts a fresh card.
                self = Builder()
                signals = AgentHomeFeedSignals(startedAt: event.createdAt, lastActivityAt: event.updatedAt)
            case .other:
                break
            }
        }

        func finished() -> AgentHomeFeedSignals {
            var signals = signals
            switch activity {
            case let .tool(name, json, input, workingDirectory):
                signals.currentActivity = AgentActivityDescriber.describe(
                    toolName: name,
                    input: input ?? json?.agentHomeJSONDictionary ?? [:],
                    workingDirectory: workingDirectory
                )
            case let .text(text):
                signals.currentActivity = text
            case nil:
                signals.currentActivity = nil
            }
            signals.pendingPermission = permission.map { permission in
                AgentHomePermissionRequest(
                    requestId: permission.requestId,
                    toolName: permission.toolName,
                    summary: AgentHomePermissionSummary.summary(
                        toolName: permission.toolName,
                        input: permission.json?.agentHomeJSONDictionary ?? [:],
                        workingDirectory: permission.workingDirectory
                    ),
                    canAlwaysAllow: permission.canAlwaysAllow
                )
            }
            return signals
        }
    }
}
