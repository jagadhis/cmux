import Foundation

/// Finds the local folder for a GitHub repository among T3 projects.
public enum GitHubRepositoryMatcher {
    /// The `owner/name` a git remote URL points at on GitHub, lowercased.
    ///
    /// Handles `https://github.com/owner/name(.git)`, `git@github.com:owner/name(.git)`
    /// and `ssh://git@github.com/owner/name`.
    public static func repository(fromRemoteURL url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "github.com") else { return nil }
        var path = String(trimmed[range.upperBound...])
        path = String(path.drop { $0 == ":" || $0 == "/" })
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return "\(parts[0])/\(parts[1])".lowercased()
    }

    /// The `origin` remote's repository from a `.git/config` file's contents.
    public static func originRepository(gitConfig: String) -> String? {
        var inOrigin = false
        for raw in gitConfig.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line == #"[remote "origin"]"#
            } else if inOrigin, line.hasPrefix("url") {
                let value = line.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
                return repository(fromRemoteURL: value)
            }
        }
        return nil
    }

    /// The project for a repository: the one whose origin remote is the repository,
    /// else the one whose folder or name is the repository's name.
    ///
    /// - Parameters:
    ///   - repository: `owner/name`.
    ///   - projects: T3 projects.
    ///   - origins: Each project's origin repository by project id, where known.
    public static func project(
        for repository: String,
        in projects: [T3CodeStateReader.Project],
        origins: [String: String]
    ) -> T3CodeStateReader.Project? {
        let wanted = repository.lowercased()
        if let match = projects.first(where: { origins[$0.id] == wanted }) { return match }
        let name = wanted.split(separator: "/").last.map(String.init) ?? wanted
        return projects.first { project in
            URL(fileURLWithPath: project.root).lastPathComponent.lowercased() == name || project.name.lowercased() == name
        }
    }
}
