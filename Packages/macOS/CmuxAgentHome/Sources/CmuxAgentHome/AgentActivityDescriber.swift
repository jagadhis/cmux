import Foundation

/// Turns an agent's latest tool call into the short "doing now" line on its card.
public enum AgentActivityDescriber {
    /// The longest line returned, in characters, before truncating with an ellipsis.
    public static let maximumLength = 72

    /// Describes a tool call as a present-tense line, such as "Reading services/voice/relay.ts".
    ///
    /// - Parameters:
    ///   - toolName: The tool name from the hook event, such as `Read` or `Bash`.
    ///   - toolInputJSON: The tool input JSON from the hook event, if any.
    ///   - workingDirectory: The task's directory; file paths under it are shown relative to it.
    /// - Returns: The line, without a trailing ellipsis unless it was truncated.
    public static func describe(toolName: String, toolInputJSON: String?, workingDirectory: String? = nil) -> String {
        let input = parse(toolInputJSON)
        func path(_ key: String = "file_path") -> String? {
            (input[key] as? String).map { display(path: $0, relativeTo: workingDirectory) }
        }
        func text(_ key: String) -> String? {
            (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }

        let line: String
        switch toolName {
        case "Read":
            line = path().map { String(localized: "agentHome.activity.readingFile", defaultValue: "Reading \($0)") }
                ?? String(localized: "agentHome.activity.readingAFile", defaultValue: "Reading a file")
        case "Edit", "MultiEdit":
            line = path().map { String(localized: "agentHome.activity.editingFile", defaultValue: "Editing \($0)") }
                ?? String(localized: "agentHome.activity.editingAFile", defaultValue: "Editing a file")
        case "Write":
            line = path().map { String(localized: "agentHome.activity.writingFile", defaultValue: "Writing \($0)") }
                ?? String(localized: "agentHome.activity.writingAFile", defaultValue: "Writing a file")
        case "NotebookEdit":
            line = path("notebook_path").map { String(localized: "agentHome.activity.editingFile", defaultValue: "Editing \($0)") }
                ?? String(localized: "agentHome.activity.editingANotebook", defaultValue: "Editing a notebook")
        case "Bash", "shell", "exec_command", "local_shell":
            if let description = text("description") {
                line = description
            } else if let command = text("command") ?? (input["command"] as? [String])?.joined(separator: " ") {
                line = String(localized: "agentHome.activity.runningCommand", defaultValue: "Running \(firstLine(of: command))")
            } else {
                line = String(localized: "agentHome.activity.runningACommand", defaultValue: "Running a command")
            }
        case "Grep":
            line = text("pattern").map { String(localized: "agentHome.activity.searchingFor", defaultValue: "Searching for \"\($0)\"") }
                ?? String(localized: "agentHome.activity.searchingTheCode", defaultValue: "Searching the code")
        case "Glob":
            line = text("pattern").map { String(localized: "agentHome.activity.findingFilesMatching", defaultValue: "Finding files matching \($0)") }
                ?? String(localized: "agentHome.activity.findingFiles", defaultValue: "Finding files")
        case "WebFetch":
            line = text("url").flatMap { URL(string: $0)?.host }.map { String(localized: "agentHome.activity.readingSite", defaultValue: "Reading \($0)") }
                ?? String(localized: "agentHome.activity.readingAWebPage", defaultValue: "Reading a web page")
        case "WebSearch":
            line = text("query").map { String(localized: "agentHome.activity.searchingTheWebFor", defaultValue: "Searching the web for \"\($0)\"") }
                ?? String(localized: "agentHome.activity.searchingTheWeb", defaultValue: "Searching the web")
        case "Task", "Agent":
            line = text("description").map { String(localized: "agentHome.activity.delegatingTask", defaultValue: "Delegating: \($0)") }
                ?? String(localized: "agentHome.activity.delegating", defaultValue: "Delegating to a subagent")
        case "TodoWrite":
            line = String(localized: "agentHome.activity.updatingPlan", defaultValue: "Updating the plan")
        case "apply_patch":
            line = String(localized: "agentHome.activity.applyingPatch", defaultValue: "Applying a patch")
        default:
            if toolName.hasPrefix("mcp__") {
                // mcp__<server>__<tool_name>: show the tool name as words.
                let rawTool = toolName.components(separatedBy: "__").last ?? toolName
                let tool = rawTool.replacingOccurrences(of: "_", with: " ")
                line = String(localized: "agentHome.activity.usingTool", defaultValue: "Using \(tool)")
            } else {
                line = String(localized: "agentHome.activity.usingTool", defaultValue: "Using \(toolName)")
            }
        }
        return truncate(line)
    }

    static func display(path: String, relativeTo directory: String?) -> String {
        if let directory, !directory.isEmpty {
            let base = directory.hasSuffix("/") ? directory : directory + "/"
            if path.hasPrefix(base) { return String(path.dropFirst(base.count)) }
        }
        let components = path.split(separator: "/")
        return components.suffix(2).joined(separator: "/")
    }

    static func firstLine(of command: String) -> String {
        command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
    }

    static func truncate(_ line: String) -> String {
        guard line.count > maximumLength else { return line }
        return String(line.prefix(maximumLength - 1)) + "…"
    }

    static func parse(_ json: String?) -> [String: Any] {
        guard let data = json?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
