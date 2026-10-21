import Foundation

/// A file an agent session wrote, from its edit tool calls.
///
/// Unlike the working tree's git status, this includes files outside the
/// repository, such as the working-memory notes an agent updates as it works.
public struct AgentSessionFile: Identifiable, Hashable, Sendable {
    /// What a file is to the user, for grouping.
    public enum Kind: Int, Comparable, Sendable, CaseIterable {
        /// Notes an agent keeps across sessions: `work-memory/`, `working-memory/`,
        /// Claude's project `memory/` folders and `MEMORY.md`.
        case workingMemory
        /// Work plans: `work-plans/` and `.claude/plans/`.
        case plan
        /// Anything else.
        case file

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The absolute path.
    public var path: String
    /// How many times the session wrote it.
    public var editCount: Int
    /// When the session last wrote it, when known.
    public var lastEditedAt: Date?

    public var id: String { path }

    /// Creates a session file.
    ///
    /// - Parameters:
    ///   - path: The absolute path.
    ///   - editCount: How many times the session wrote it.
    ///   - lastEditedAt: When the session last wrote it.
    public init(path: String, editCount: Int = 1, lastEditedAt: Date? = nil) {
        self.path = path
        self.editCount = editCount
        self.lastEditedAt = lastEditedAt
    }

    /// What the file is, from its path.
    public var kind: Kind { Self.kind(ofPath: path) }

    /// Classifies a path as working memory, a plan or another file.
    static func kind(ofPath path: String) -> Kind {
        let components = path.split(separator: "/").map(String.init)
        let directories = components.dropLast()
        if directories.contains(where: { $0 == "work-memory" || $0 == "working-memory" })
            || components.last == "MEMORY.md" {
            return .workingMemory
        }
        // Claude Code's auto memory: ~/.claude/projects/<project>/memory/.
        if let claude = directories.firstIndex(of: ".claude"), directories[claude...].contains("memory") {
            return .workingMemory
        }
        if directories.contains("work-plans") {
            return .plan
        }
        if let claude = directories.firstIndex(of: ".claude"), directories[claude...].contains("plans") {
            return .plan
        }
        return .file
    }

    /// The path to show: relative to `root` when inside it, else with the home folder as `~`.
    ///
    /// - Parameters:
    ///   - root: The session's project or worktree folder.
    ///   - home: The home folder. Defaults to the current user's.
    public func displayPath(relativeTo root: String?, home: String = NSHomeDirectory()) -> String {
        if let root = root.map(\.trimmingTrailingSlash), !root.isEmpty, path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        let home = home.trimmingTrailingSlash
        if !home.isEmpty, path.hasPrefix(home + "/") {
            return "~/" + path.dropFirst(home.count + 1)
        }
        return path
    }

    /// Merges per-session lists into one, adding edit counts and keeping the latest edit time.
    ///
    /// - Returns: The files, most recently edited first.
    public static func merged(_ lists: [[AgentSessionFile]]) -> [AgentSessionFile] {
        var byPath: [String: AgentSessionFile] = [:]
        for file in lists.joined() {
            if var existing = byPath[file.path] {
                existing.editCount += file.editCount
                existing.lastEditedAt = [existing.lastEditedAt, file.lastEditedAt].compactMap { $0 }.max()
                byPath[file.path] = existing
            } else {
                byPath[file.path] = file
            }
        }
        return sorted(Array(byPath.values))
    }

    /// Most recently edited first; files with no time last, then by path.
    public static func sorted(_ files: [AgentSessionFile]) -> [AgentSessionFile] {
        files.sorted { lhs, rhs in
            switch (lhs.lastEditedAt, rhs.lastEditedAt) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.path < rhs.path
            }
        }
    }

    /// Resolves a tool's path against the session's folder and normalizes `.` and `..`.
    ///
    /// - Returns: The absolute path, or `nil` for a relative path with no folder to resolve it against.
    public static func absolutePath(_ path: String, relativeTo directory: String?) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            return (trimmed as NSString).standardizingPath
        }
        if trimmed.hasPrefix("~/") {
            return (trimmed as NSString).expandingTildeInPath
        }
        guard let directory, directory.hasPrefix("/") else { return nil }
        return ((directory as NSString).appendingPathComponent(trimmed) as NSString).standardizingPath
    }

}

/// The files one agent session wrote, built from its tool calls as they arrive.
public struct AgentSessionFileLog: Hashable, Sendable {
    private var byPath: [String: AgentSessionFile] = [:]

    public init() {}

    /// The files, most recently edited first.
    public var files: [AgentSessionFile] { AgentSessionFile.sorted(Array(byPath.values)) }

    public var isEmpty: Bool { byPath.isEmpty }

    /// Records the files a tool call writes, if it writes any.
    ///
    /// - Parameters:
    ///   - toolName: The tool name from the hook event, such as `Edit` or `apply_patch`.
    ///   - toolInputJSON: The tool input JSON from the hook event.
    ///   - workingDirectory: The session's folder, for relative paths.
    ///   - date: When the call happened.
    public mutating func record(toolName: String, toolInputJSON: String?, workingDirectory: String?, at date: Date?) {
        guard Self.mayWrite(toolName: toolName, toolInputJSON: toolInputJSON) else { return }
        record(toolName: toolName, input: toolInputJSON?.agentHomeJSONObject, toolInputJSON: toolInputJSON, workingDirectory: workingDirectory, at: date)
    }

    /// Records the files a tool call writes, with its input already parsed.
    mutating func record(toolName: String, input: Any?, toolInputJSON: String?, workingDirectory: String?, at date: Date?) {
        for path in Self.writtenPaths(toolName: toolName, input: input, toolInputJSON: toolInputJSON, workingDirectory: workingDirectory) {
            record(path: path, at: date)
        }
    }

    /// Records one write to an absolute path.
    public mutating func record(path: String, at date: Date?) {
        var file = byPath[path] ?? AgentSessionFile(path: path, editCount: 0)
        file.editCount += 1
        file.lastEditedAt = [file.lastEditedAt, date].compactMap { $0 }.max()
        byPath[path] = file
    }

    /// Whether a tool call can write files, checked without parsing its input.
    /// Most calls are reads and commands.
    static func mayWrite(toolName: String, toolInputJSON: String?) -> Bool {
        writingToolNames.contains(toolName) || toolInputJSON?.contains("*** Begin Patch") == true
    }

    private static let writingToolNames: Set<String> = ["Edit", "MultiEdit", "Write", "str_replace_based_edit_tool", "NotebookEdit"]

    /// The absolute paths a tool call writes: Claude's `Edit`, `MultiEdit`,
    /// `Write` and `NotebookEdit`, and the files an `apply_patch` patch adds,
    /// updates or moves to. Deleted files aren't listed, since they can't be opened.
    static func writtenPaths(toolName: String, toolInputJSON: String?, workingDirectory: String?) -> [String] {
        guard mayWrite(toolName: toolName, toolInputJSON: toolInputJSON) else { return [] }
        return writtenPaths(toolName: toolName, input: toolInputJSON?.agentHomeJSONObject, toolInputJSON: toolInputJSON, workingDirectory: workingDirectory)
    }

    static func writtenPaths(toolName: String, input: Any?, toolInputJSON: String?, workingDirectory: String?) -> [String] {
        let object = input as? [String: Any] ?? [:]
        let raw: [String]
        switch toolName {
        case "Edit", "MultiEdit", "Write", "str_replace_based_edit_tool":
            raw = [(object["file_path"] ?? object["path"]) as? String].compactMap { $0 }
        case "NotebookEdit":
            raw = [object["notebook_path"] as? String].compactMap { $0 }
        default:
            // Codex sends patches as apply_patch, or as a shell command running it.
            raw = patchTexts(in: input ?? toolInputJSON as Any).flatMap(patchPaths(in:))
        }
        var seen = Set<String>()
        return raw.compactMap { AgentSessionFile.absolutePath($0, relativeTo: workingDirectory) }
            .filter { seen.insert($0).inserted }
    }

    /// The file paths a patch in Codex's `*** Begin Patch` format adds, updates or moves to.
    static func patchPaths(in patch: String) -> [String] {
        var paths: [String] = []
        for line in patch.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("*** Add File: ") || line.hasPrefix("*** Update File: ") {
                paths.append(String(line.drop { $0 != ":" }.dropFirst(2)))
            } else if line.hasPrefix("*** Move to: "), !paths.isEmpty {
                // An update followed by a move writes only the destination.
                paths[paths.count - 1] = String(line.dropFirst("*** Move to: ".count))
            }
        }
        return paths
    }

    private static func patchTexts(in value: Any) -> [String] {
        switch value {
        case let text as String:
            return text.contains("*** Begin Patch") ? [text] : []
        case let array as [Any]:
            return array.flatMap(patchTexts(in:))
        case let object as [String: Any]:
            return object.values.flatMap(patchTexts(in:))
        default:
            return []
        }
    }
}
