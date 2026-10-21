import Foundation

/// A cmux project (workspace group) as T3 linking sees it.
public struct T3LinkGroup: Hashable, Sendable {
    /// The workspace group id.
    public var id: UUID
    /// The group name.
    public var name: String
    /// The group's external id, `t3:<project id>` for groups Agent Home created.
    public var externalID: String?
    /// The group's home directory: its anchor workspace's working directory.
    public var directory: String?

    /// Creates a link group.
    ///
    /// - Parameters:
    ///   - id: The workspace group id.
    ///   - name: The group name.
    ///   - externalID: The group's external id.
    ///   - directory: The group's home directory.
    public init(id: UUID, name: String, externalID: String? = nil, directory: String? = nil) {
        self.id = id
        self.name = name
        self.externalID = externalID
        self.directory = directory
    }
}

/// Connects T3 projects and tasks to cmux projects and workspaces.
public enum T3Linking {
    /// The external id Agent Home gives a group it creates for a T3 project.
    ///
    /// - Parameter projectId: The T3 project id.
    /// - Returns: The external id.
    public static func externalID(forProjectId projectId: String) -> String {
        "t3:\(projectId)"
    }

    /// The cmux project a T3 project belongs to.
    ///
    /// Matches, in order: a group Agent Home created for this T3 project, a
    /// group whose home directory is the T3 project's root, then a group
    /// with the same name (case-insensitive).
    ///
    /// - Parameters:
    ///   - projectId: The T3 project id.
    ///   - projectName: The T3 project title.
    ///   - projectRoot: The T3 project's root directory.
    ///   - groups: The cmux workspace groups.
    /// - Returns: The matching group id, or `nil` when none matches.
    public static func groupId(
        forProjectId projectId: String,
        projectName: String,
        projectRoot: String?,
        in groups: [T3LinkGroup]
    ) -> UUID? {
        let externalID = externalID(forProjectId: projectId)
        if let match = groups.first(where: { $0.externalID == externalID }) { return match.id }
        if let root = projectRoot.map(normalized),
           let match = groups.first(where: { $0.directory.map(normalized) == root }) {
            return match.id
        }
        let name = projectName.lowercased()
        return groups.first { $0.name.lowercased() == name }?.id
    }

    static func normalized(_ path: String) -> String {
        var path = (path as NSString).standardizingPath
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        return path
    }
}
