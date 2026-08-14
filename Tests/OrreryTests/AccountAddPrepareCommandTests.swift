import ArgumentParser
import Foundation
import Testing
@testable import OrreryCore

#if os(macOS)
@Suite("AccountAddPrepareCommand.patchAutoFinalizeHook")
struct AccountAddPrepareCommandTests {

    @Test("installs a Notification/auth_success hook pointing at _account-add-finalize --keep-staging")
    func installsAutoFinalizeHook() throws {
        let stagingDir = makeStagingDir()
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        AccountAddPrepareCommand.patchAutoFinalizeHook(
            stagingDir: stagingDir, orreryBinPath: "/usr/local/bin/orrery-bin"
        )

        let settingsURL = stagingDir.appendingPathComponent("settings.json")
        let data = try Data(contentsOf: settingsURL)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(obj["hooks"] as? [String: Any])
        let notifications = try #require(hooks["Notification"] as? [[String: Any]])
        #expect(notifications.count == 1)
        #expect(notifications.first?["matcher"] as? String == "auth_success")
        let innerHooks = try #require(notifications.first?["hooks"] as? [[String: Any]])
        #expect(innerHooks.first?["command"] as? String
            == "/usr/local/bin/orrery-bin _account-add-finalize --staging \(stagingDir.path) --keep-staging")
    }

    @Test("preserves existing settings.json content")
    func preservesExistingSettings() throws {
        let stagingDir = makeStagingDir()
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        let settingsURL = stagingDir.appendingPathComponent("settings.json")
        try #"{"theme":"dark"}"#.write(to: settingsURL, atomically: true, encoding: .utf8)

        AccountAddPrepareCommand.patchAutoFinalizeHook(
            stagingDir: stagingDir, orreryBinPath: "/usr/local/bin/orrery-bin"
        )

        let data = try Data(contentsOf: settingsURL)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["theme"] as? String == "dark")
        #expect(obj["hooks"] != nil)
    }

    @Test("is idempotent — a second call with the same staging dir doesn't duplicate the entry")
    func idempotent() throws {
        let stagingDir = makeStagingDir()
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        AccountAddPrepareCommand.patchAutoFinalizeHook(
            stagingDir: stagingDir, orreryBinPath: "/usr/local/bin/orrery-bin"
        )
        AccountAddPrepareCommand.patchAutoFinalizeHook(
            stagingDir: stagingDir, orreryBinPath: "/usr/local/bin/orrery-bin"
        )

        let data = try Data(contentsOf: stagingDir.appendingPathComponent("settings.json"))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(obj["hooks"] as? [String: Any])
        let notifications = try #require(hooks["Notification"] as? [[String: Any]])
        #expect(notifications.count == 1)
    }

    // MARK: - Helpers

    private func makeStagingDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-login-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
#endif
