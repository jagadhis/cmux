import CMUXAgentLaunch
import CmuxAgentHome
import Foundation

/// What the Feed knows about one agent terminal, for its Agent Home card.
struct AgentHomeFeedSignals: Equatable {
    var pendingPermission: AgentHomePermissionRequest?
    var currentActivity: String?
    var plan: [AgentHomePlanStep] = []
    var lastSummary: String?
    /// The current session's first prompt, as a card title.
    var sessionTitle: String?
    var startedAt: Date?
    var lastActivityAt: Date?
}

/// Folds Feed items into per-terminal signals.
///
/// Items reach a terminal through their workstream's resolved target, so the
/// result is keyed by surface (panel) id, uppercased to match `UUID.uuidString`.
enum AgentHomeFeedIndex {
    static func signals(
        items: [WorkstreamItem],
        targets: [String: FeedJumpResolver.Target]
    ) -> [String: AgentHomeFeedSignals] {
        var result: [String: AgentHomeFeedSignals] = [:]
        for item in items.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let target = targets[item.workstreamId] else { continue }
            let key = target.surfaceId.uppercased()
            var signals = result[key] ?? AgentHomeFeedSignals()
            signals.startedAt = signals.startedAt ?? item.createdAt
            signals.lastActivityAt = max(signals.lastActivityAt ?? item.updatedAt, item.updatedAt)

            switch item.payload {
            case let .permissionRequest(requestId, toolName, toolInputJSON, _):
                if item.status.isPending {
                    signals.pendingPermission = AgentHomePermissionRequest(
                        requestId: requestId,
                        toolName: toolName,
                        summary: AgentHomePermissionSummary.summary(
                            toolName: toolName,
                            toolInputJSON: toolInputJSON,
                            workingDirectory: item.cwd
                        ),
                        canAlwaysAllow: FeedPermissionActionPolicy.supportsAlwaysPermissionMode(
                            source: item.source,
                            toolInputJSON: toolInputJSON
                        )
                    )
                } else if signals.pendingPermission?.requestId == requestId {
                    signals.pendingPermission = nil
                }
            case let .toolUse(toolName, toolInputJSON):
                if toolName == "TodoWrite" {
                    let steps = AgentHomePlanParser.steps(fromToolInputJSON: toolInputJSON)
                    if !steps.isEmpty { signals.plan = steps }
                }
                signals.currentActivity = AgentActivityDescriber.describe(
                    toolName: toolName,
                    toolInputJSON: toolInputJSON,
                    workingDirectory: item.cwd
                )
            case let .todos(todos):
                signals.plan = todos.map { todo in
                    let status: AgentHomePlanStep.Status
                    switch todo.state {
                    case .completed: status = .completed
                    case .inProgress: status = .inProgress
                    case .pending: status = .pending
                    }
                    return AgentHomePlanStep(title: todo.content, status: status)
                }
            case let .userPrompt(text):
                if signals.sessionTitle == nil { signals.sessionTitle = AgentHomeText.title(fromPrompt: text) }
                signals.currentActivity = String(localized: "agentHome.activity.readingPrompt", defaultValue: "Reading your message")
            case let .assistantMessage(text):
                if let summary = AgentHomeText.summary(fromMarkdown: text) { signals.lastSummary = summary }
            case let .stop(reason):
                signals.currentActivity = nil
                if let reason, let summary = AgentHomeText.summary(fromMarkdown: reason) { signals.lastSummary = summary }
            case .sessionEnd:
                signals.currentActivity = nil
            case .sessionStart:
                // A new session in the same terminal starts a fresh card.
                signals = AgentHomeFeedSignals(startedAt: item.createdAt, lastActivityAt: item.updatedAt)
            case .toolResult, .exitPlan, .question:
                break
            }
            result[key] = signals
        }
        return result
    }
}
