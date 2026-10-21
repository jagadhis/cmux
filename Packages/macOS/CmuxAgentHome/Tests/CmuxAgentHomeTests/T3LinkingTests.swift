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
}
