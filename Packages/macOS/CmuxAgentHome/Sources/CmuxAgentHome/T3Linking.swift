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

/// A cmux task (workspace) as T3 linking sees it.
public struct T3LinkWorkspace: Hashable, Sendable {
    /// The workspace id.
    public var id: UUID
    /// The workspace title.
    public var title: String
    /// The workspace group id.
    public var groupId: UUID?
    /// The working directory.
    public var directory: String?

    /// Creates a link workspace.
    ///
    /// - Parameters:
    ///   - id: The workspace id.
    ///   - title: The workspace title.
    ///   - groupId: The workspace group id.
    ///   - directory: The working directory.
    public init(id: UUID, title: String, groupId: UUID? = nil, directory: String? = nil) {
        self.id = id
        self.title = title
        self.groupId = groupId
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

    /// The workspace a T3 task is already open in, if any.
    ///
    /// A recorded link wins while its workspace still exists. Otherwise a
    /// workspace in the same project with the task's title and directory counts.
    ///
    /// - Parameters:
    ///   - proposal: The T3 task.
    ///   - linkedWorkspaceId: The workspace recorded when the task was last opened.
    ///   - groupId: The cmux project the task belongs to.
    ///   - workspaces: The cmux workspaces.
    /// - Returns: The workspace id, or `nil` when the task isn't open.
    public static func openWorkspaceId(
        for proposal: T3TaskProposal,
        linkedWorkspaceId: UUID?,
        groupId: UUID?,
        in workspaces: [T3LinkWorkspace]
    ) -> UUID? {
        if let linkedWorkspaceId, workspaces.contains(where: { $0.id == linkedWorkspaceId }) {
            return linkedWorkspaceId
        }
        let directory = (proposal.worktreePath ?? proposal.projectRoot).map(normalized)
        return workspaces.first { workspace in
            workspace.groupId == groupId
                && workspace.title == proposal.title
                && workspace.directory.map(normalized) == directory
        }?.id
    }

    /// The directory to open a T3 task in: its worktree, else its project root.
    ///
    /// - Parameter proposal: The T3 task.
    /// - Returns: The directory, or `nil` when T3 recorded neither.
    public static func directory(for proposal: T3TaskProposal) -> String? {
        proposal.worktreePath ?? proposal.projectRoot
    }

    static func normalized(_ path: String) -> String {
        var path = (path as NSString).standardizingPath
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        return path
    }
}
