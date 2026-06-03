import Foundation
import Testing
@testable import OrreryCore

@Suite("EnvironmentStore.claudeWorkspaceDir")
struct EnvironmentStoreWorkspaceTests {
    @Test("origin's claude dir lives under workspaces/origin/")
    func originWorkspaceDir() throws {
        try withIsolatedHome {
            let store = EnvironmentStore.default
            let home = orreryHomeURL()
            let dir = store.claudeWorkspaceDir(workspace: "origin")
            #expect(dir.path == home.appendingPathComponent("workspaces/origin/claude").path)
        }
    }

    @Test("named workspace's claude dir lives under workspaces/<name>/")
    func namedWorkspaceDir() throws {
        try withIsolatedHome {
            let store = EnvironmentStore.default
            let home = orreryHomeURL()
            let dir = store.claudeWorkspaceDir(workspace: "work")
            #expect(dir.path == home.appendingPathComponent("workspaces/work/claude").path)
        }
    }

    @Test("claudeWorkspaceDir points under workspaces/<ws>/claude (no claude-workspace)")
    func claudeWorkspaceDirNewLayout() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-wslayout-\(UUID().uuidString)")
        let store = EnvironmentStore(homeURL: home)
        #expect(store.claudeWorkspaceDir(workspace: "origin").path
            == home.appendingPathComponent("workspaces/origin/claude").path)
        #expect(store.claudeWorkspaceDir(workspace: "ABC-UUID").path
            == home.appendingPathComponent("workspaces/ABC-UUID/claude").path)
    }

    @Test("originDir lives under workspaces/origin")
    func originDirNewLayout() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-origindir-\(UUID().uuidString)")
        let store = EnvironmentStore(homeURL: home)
        #expect(store.originDir.path == home.appendingPathComponent("workspaces/origin").path)
        #expect(store.originConfigDir(tool: .claude).path
            == home.appendingPathComponent("workspaces/origin/claude").path)
    }
}
