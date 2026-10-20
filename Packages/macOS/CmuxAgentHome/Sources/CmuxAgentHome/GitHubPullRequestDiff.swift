import Foundation

/// A file a pull request changes, with its diff as GitHub returns it
/// (`GET /repos/{owner}/{repo}/pulls/{number}/files`).
public struct GitHubPullRequestFile: Identifiable, Hashable, Sendable {
    public enum Status: String, Sendable {
        case added, removed, modified, renamed, copied, changed, unchanged
    }

    /// The file's path in the head commit.
    public var path: String
    /// The path before a rename.
    public var previousPath: String?
    public var status: Status
    public var additions: Int
    public var deletions: Int
    /// The unified diff, without file headers. GitHub leaves it out for
    /// binary files and very large diffs.
    public var patch: String?

    public var id: String { path }

    public init(path: String, previousPath: String? = nil, status: Status, additions: Int, deletions: Int, patch: String?) {
        self.path = path
        self.previousPath = previousPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.patch = patch
    }

    /// The diff, split into hunks. Empty when GitHub didn't include one.
    public var hunks: [GitHubDiffHunk] { patch.map(GitHubDiffHunk.parse) ?? [] }

    /// Reads one entry of the REST files list.
    public static func fromREST(_ object: [String: Any]) -> GitHubPullRequestFile? {
        guard let path = object["filename"] as? String else { return nil }
        return GitHubPullRequestFile(
            path: path,
            previousPath: object["previous_filename"] as? String,
            status: (object["status"] as? String).flatMap(Status.init(rawValue:)) ?? .modified,
            additions: (object["additions"] as? NSNumber)?.intValue ?? 0,
            deletions: (object["deletions"] as? NSNumber)?.intValue ?? 0,
            patch: object["patch"] as? String
        )
    }

    /// Orders files as a reviewer reads them: by directory, then name, so a
    /// folder's files sit together (T3 sorts its code tab the same way).
    public static func reviewOrder(_ files: [GitHubPullRequestFile]) -> [GitHubPullRequestFile] {
        files.sorted { lhs, rhs in
            let left = (lhs.path as NSString).deletingLastPathComponent
            let right = (rhs.path as NSString).deletingLastPathComponent
            if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }
}

/// One hunk of a unified diff.
public struct GitHubDiffHunk: Hashable, Sendable {
    /// One line of a hunk.
    public struct Line: Hashable, Sendable {
        public enum Kind: Sendable { case context, addition, deletion, noNewline }

        public var kind: Kind
        public var text: String
        /// The line number in the old file, for context and deleted lines.
        public var oldNumber: Int?
        /// The line number in the new file, for context and added lines.
        public var newNumber: Int?

        public init(kind: Kind, text: String, oldNumber: Int?, newNumber: Int?) {
            self.kind = kind
            self.text = text
            self.oldNumber = oldNumber
            self.newNumber = newNumber
        }
    }

    /// The `@@ -a,b +c,d @@ section` line.
    public var header: String
    public var lines: [Line]

    public init(header: String, lines: [Line]) {
        self.header = header
        self.lines = lines
    }

    /// Splits a unified diff into hunks with line numbers.
    public static func parse(_ patch: String) -> [GitHubDiffHunk] {
        var hunks: [GitHubDiffHunk] = []
        var oldLine = 0
        var newLine = 0
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                let (old, new) = startLines(of: line)
                oldLine = old
                newLine = new
                hunks.append(GitHubDiffHunk(header: line, lines: []))
                continue
            }
            guard !hunks.isEmpty else { continue }
            let body = String(line.dropFirst())
            switch line.first {
            case "+":
                hunks[hunks.count - 1].lines.append(Line(kind: .addition, text: body, oldNumber: nil, newNumber: newLine))
                newLine += 1
            case "-":
                hunks[hunks.count - 1].lines.append(Line(kind: .deletion, text: body, oldNumber: oldLine, newNumber: nil))
                oldLine += 1
            case "\\":
                hunks[hunks.count - 1].lines.append(Line(kind: .noNewline, text: line, oldNumber: nil, newNumber: nil))
            default:
                // A context line, or the empty last line a trailing newline leaves.
                if line.isEmpty, raw.endIndex == patch.endIndex { continue }
                hunks[hunks.count - 1].lines.append(Line(kind: .context, text: body, oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
            }
        }
        return hunks
    }

    /// The first old and new line numbers from `@@ -12,7 +12,9 @@`.
    static func startLines(of header: String) -> (Int, Int) {
        func number(after marker: Character) -> Int {
            guard let start = header.firstIndex(of: marker) else { return 1 }
            let digits = header[header.index(after: start)...].prefix { $0.isNumber }
            return Int(digits) ?? 1
        }
        return (number(after: "-"), number(after: "+"))
    }
}
