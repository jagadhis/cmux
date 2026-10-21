import Foundation

/// Reads an agent's plan from a `TodoWrite`-style tool input.
public enum AgentHomePlanParser {
    /// Parses plan steps from a tool input such as Claude's
    /// `{"todos":[{"content":"…","status":"in_progress"}]}`, or a bare array of the same objects.
    ///
    /// - Parameter json: The tool input JSON.
    /// - Returns: The steps in order; empty when the input has none.
    public static func steps(fromToolInputJSON json: String?) -> [AgentHomePlanStep] {
        steps(from: json?.agentHomeJSONObject)
    }

    /// Plan steps from a tool input that's already parsed.
    static func steps(from object: Any?) -> [AgentHomePlanStep] {
        guard let object else { return [] }
        let rawSteps = (object as? [String: Any])?["todos"] as? [Any] ?? object as? [Any] ?? []
        return rawSteps.compactMap { raw in
            guard let step = raw as? [String: Any] else { return nil }
            let title = ((step["content"] ?? step["text"] ?? step["title"]) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            return AgentHomePlanStep(title: title, status: status(from: (step["status"] ?? step["state"]) as? String))
        }
    }

    static func status(from raw: String?) -> AgentHomePlanStep.Status {
        switch raw?.lowercased() {
        case "completed", "complete", "done": return .completed
        case "in_progress", "inprogress", "in-progress", "active": return .inProgress
        default: return .pending
        }
    }
}

/// Summarises a permission request as the one line shown on its card.
public enum AgentHomePermissionSummary {
    /// The line to show for a permission request: the shell command for
    /// shell tools, otherwise the tool's "doing now" description.
    ///
    /// - Parameters:
    ///   - toolName: The tool the agent wants to run.
    ///   - toolInputJSON: The tool input JSON.
    ///   - workingDirectory: The task's directory, for relative file paths.
    /// - Returns: The summary line.
    public static func summary(toolName: String, toolInputJSON: String?, workingDirectory: String? = nil) -> String {
        summary(toolName: toolName, input: toolInputJSON?.agentHomeJSONDictionary ?? [:], workingDirectory: workingDirectory)
    }

    /// The summary line for a request whose tool input is already parsed.
    static func summary(toolName: String, input: [String: Any], workingDirectory: String?) -> String {
        if ["Bash", "shell", "exec_command", "local_shell"].contains(toolName) {
            let command = (input["command"] as? String) ?? (input["command"] as? [String])?.joined(separator: " ")
            if let command, !command.isEmpty {
                return AgentActivityDescriber.firstLine(of: command.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return AgentActivityDescriber.describe(toolName: toolName, input: input, workingDirectory: workingDirectory)
    }
}
