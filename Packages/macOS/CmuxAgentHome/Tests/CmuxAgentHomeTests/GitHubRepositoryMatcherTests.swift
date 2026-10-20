import Foundation
import Testing
@testable import CmuxAgentHome

@Suite struct GitHubRepositoryMatcherTests {
    @Test func parsesRemoteURLs() {
        #expect(GitHubRepositoryMatcher.repository(fromRemoteURL: "https://github.com/phas-io/Nebula.git") == "phas-io/nebula")
        #expect(GitHubRepositoryMatcher.repository(fromRemoteURL: "git@github.com:jagadhis/cmux.git") == "jagadhis/cmux")
        #expect(GitHubRepositoryMatcher.repository(fromRemoteURL: "ssh://git@github.com/jagadhis/switchboard") == "jagadhis/switchboard")
        #expect(GitHubRepositoryMatcher.repository(fromRemoteURL: "https://gitlab.com/a/b.git") == nil)
    }

    @Test func readsOriginFromGitConfig() {
        let config = """
            [core]
            \trepositoryformatversion = 0
            [remote "upstream"]
            \turl = https://github.com/manaflow-ai/cmux.git
            [remote "origin"]
            \turl = git@github.com:jagadhis/cmux.git
            \tfetch = +refs/heads/*:refs/remotes/origin/*
            """
        #expect(GitHubRepositoryMatcher.originRepository(gitConfig: config) == "jagadhis/cmux")
    }

    @Test func matchesByOriginThenFolderName() {
        let projects = [
            T3CodeStateReader.Project(id: "a", name: "nebula-old", root: "/Users/j/old/Nebula"),
            T3CodeStateReader.Project(id: "b", name: "Nebula main", root: "/Users/j/work/neb"),
            T3CodeStateReader.Project(id: "c", name: "switchboard", root: "/Users/j/sb"),
        ]
        #expect(GitHubRepositoryMatcher.project(for: "phas-io/Nebula", in: projects, origins: ["b": "phas-io/nebula"])?.id == "b")
        #expect(GitHubRepositoryMatcher.project(for: "phas-io/Nebula", in: projects, origins: [:])?.id == "a")
        #expect(GitHubRepositoryMatcher.project(for: "jagadhis/switchboard", in: projects, origins: [:])?.id == "c")
        #expect(GitHubRepositoryMatcher.project(for: "x/unknown", in: projects, origins: [:]) == nil)
    }
}
