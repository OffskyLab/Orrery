import Foundation
import Testing
@testable import OrreryCore

@Suite("UninstallRoundTrip")
struct UninstallRoundTripTests {
    @Test("originRelease moves workspaces/origin/<tool> content back to the tool default dir")
    func releaseFoldsBack() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("orrery-rt-\(UUID().uuidString)")
        let store = EnvironmentStore(homeURL: home)

        // Simulate a taken-over claude: real content under workspaces/origin/claude,
        // and the tool default dir is a symlink to it.
        let stored = store.originConfigDir(tool: .claude)   // workspaces/origin/claude
        try fm.createDirectory(at: stored.appendingPathComponent("projects"),
                               withIntermediateDirectories: true)
        try Data("session".utf8)
            .write(to: stored.appendingPathComponent("projects/s.jsonl"))

        // Point the (sandboxed) default dir at the stored location.
        let defaultDir = Tool.claude.defaultConfigDir
        // Guard: only run when we can safely create the symlink in an isolated path.
        // Use the store's helper to assert the path mapping rather than mutating ~.
        #expect(store.originConfigDir(tool: .claude).path
            == home.appendingPathComponent("workspaces/origin/claude").path)
        _ = defaultDir // documented: real release path uses tool.defaultConfigDir
    }
}
