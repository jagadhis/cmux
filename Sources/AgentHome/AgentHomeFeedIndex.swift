import CMUXAgentLaunch
import CmuxAgentHome
import Foundation

/// Maps Feed items to the events Agent Home's fold reads.
///
/// Items reach a terminal through their workstream's resolved target, so each
/// event is keyed by surface (panel) id, uppercased to match `UUID.uuidString`.
/// Items whose workstream isn't resolved yet are left out.
enum AgentHomeFeedIndex {
    static func events(
        items: [WorkstreamItem],
        targets: [String: FeedJumpResolver.Target]
    ) -> [AgentHomeFeedEvent] {
        items.compactMap { item in
            guard let target = targets[item.workstreamId] else { return nil }
            return AgentHomeFeedEvent(
                terminalKey: target.surfaceId.uppercased(),
                createdAt: item.createdAt,
                updatedAt: item.updatedAt,
                workingDirectory: item.cwd,
                payload: payload(for: item)
            )
        }
    }

    private static func payload(for item: WorkstreamItem) -> AgentHomeFeedEvent.Payload {
        switch item.payload {
        case let .permissionRequest(requestId, toolName, toolInputJSON, _):
            let isPending = item.status.isPending
            return .permissionRequest(
                requestId: requestId,
                toolName: toolName,
                toolInputJSON: toolInputJSON,
                isPending: isPending,
                canAlwaysAllow: isPending && FeedPermissionActionPolicy.supportsAlwaysPermissionMode(
                    source: item.source,
                    toolInputJSON: toolInputJSON
                )
            )
        case let .toolUse(toolName, toolInputJSON):
            return .toolUse(toolName: toolName, toolInputJSON: toolInputJSON)
        case let .todos(todos):
            return .plan(todos.map { todo in
                let status: AgentHomePlanStep.Status
                switch todo.state {
                case .completed: status = .completed
                case .inProgress: status = .inProgress
                case .pending: status = .pending
                }
                return AgentHomePlanStep(title: todo.content, status: status)
            })
        case let .userPrompt(text):
            return .userPrompt(text)
        case let .assistantMessage(text):
            return .assistantMessage(text)
        case let .stop(reason):
            return .stop(reason: reason)
        case .sessionEnd:
            return .sessionEnd
        case .sessionStart:
            return .sessionStart
        case .toolResult, .exitPlan, .question:
            return .other
        }
    }
}
