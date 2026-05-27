import Foundation
import Testing
@testable import OrreryCore

@Suite("EnvironmentStore.claudeWorkspaceDir")
struct EnvironmentStoreWorkspaceTests {
    @Test("origin's claude-workspace lives under envs/origin/")
    func originWorkspaceDir() throws {
        try withIsolatedHome {
            let store = EnvironmentStore.default
            let home = orreryHomeURL()
            let dir = store.claudeWorkspaceDir(workspace: "origin")
            #expect(dir.path == home.appendingPathComponent("envs/origin/claude-workspace").path)
        }
    }

    @Test("named workspace's claude-workspace lives under envs/<name>/")
    func namedWorkspaceDir() throws {
        try withIsolatedHome {
            let store = EnvironmentStore.default
            let home = orreryHomeURL()
            let dir = store.claudeWorkspaceDir(workspace: "work")
            #expect(dir.path == home.appendingPathComponent("envs/work/claude-workspace").path)
        }
    }
}
