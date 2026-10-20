import Foundation
import Testing
@testable import CmuxAgentHome

@Suite struct T3LinkingTests {
    let created = T3LinkGroup(id: UUID(), name: "Renamed", externalID: "t3:p1")
    let byDirectory = T3LinkGroup(id: UUID(), name: "app", directory: "/Users/jags/projects/oorva-app/")
    let byName = T3LinkGroup(id: UUID(), name: "OORVA-APP")

    @Test func externalIDWinsThenDirectoryThenName() {
        #expect(T3Linking.groupId(forProjectId: "p1", projectName: "oorva-app", projectRoot: "/Users/jags/projects/oorva-app", in: [byName, byDirectory, created]) == created.id)
        #expect(T3Linking.groupId(forProjectId: "p2", projectName: "oorva-app", projectRoot: "/Users/jags/projects/oorva-app", in: [byName, byDirectory]) == byDirectory.id)
        #expect(T3Linking.groupId(forProjectId: "p2", projectName: "oorva-app", projectRoot: "/elsewhere", in: [byName, byDirectory]) == byName.id)
        #expect(T3Linking.groupId(forProjectId: "p2", projectName: "tachyon", projectRoot: nil, in: [byName, byDirectory]) == nil)
    }

    @Test func privateTmpPathsMatch() {
        let group = T3LinkGroup(id: UUID(), name: "demo", directory: "/private/tmp/demo")
        #expect(T3Linking.groupId(forProjectId: "x", projectName: "other", projectRoot: "/tmp/demo", in: [group]) == group.id)
    }

    func proposal(worktree: String? = "/Users/jags/projects/oorva-app") -> T3TaskProposal {
        let result = T3ThreadGrouping.group([
            T3Thread(id: "t1", projectId: "p1", projectName: "oorva-app", projectRoot: "/Users/jags/projects/oorva-app",
                     title: "Voice relay", branch: "feat/voice", worktreePath: worktree, provider: "claudeAgent"),
        ])
        return result.tasks[0]
    }

    @Test func linkedWorkspaceWinsWhileItExists() {
        let group = UUID()
        let linked = T3LinkWorkspace(id: UUID(), title: "Renamed by user", groupId: group, directory: "/somewhere")
        #expect(T3Linking.openWorkspaceId(for: proposal(), linkedWorkspaceId: linked.id, groupId: group, in: [linked]) == linked.id)
        #expect(T3Linking.openWorkspaceId(for: proposal(), linkedWorkspaceId: UUID(), groupId: group, in: [linked]) == nil)
    }

    @Test func matchingTitleAndDirectoryCountsAsOpen() {
        let group = UUID()
        let match = T3LinkWorkspace(id: UUID(), title: "Voice relay", groupId: group, directory: "/Users/jags/projects/oorva-app")
        let otherGroup = T3LinkWorkspace(id: UUID(), title: "Voice relay", groupId: UUID(), directory: "/Users/jags/projects/oorva-app")
        #expect(T3Linking.openWorkspaceId(for: proposal(), linkedWorkspaceId: nil, groupId: group, in: [otherGroup, match]) == match.id)
    }

    @Test func directoryFallsBackToProjectRoot() {
        #expect(T3Linking.directory(for: proposal(worktree: nil)) == "/Users/jags/projects/oorva-app")
        #expect(T3Linking.externalID(forProjectId: "abc") == "t3:abc")
    }
}
