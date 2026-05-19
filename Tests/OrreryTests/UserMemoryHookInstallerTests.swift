import Testing
import Foundation
@testable import OrreryCore

@Suite("ClaudeHookInstaller")
struct ClaudeHookInstallerTests {
    let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-claudehook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    @Test("install on empty config creates settings.json with our hook entry")
    func installEmpty() throws {
        let installer = ClaudeHookInstaller()
        try installer.install(at: tmpDir)
        let settings = tmpDir.appendingPathComponent("settings.json")
        let body = try String(contentsOf: settings, encoding: .utf8)
        #expect(body.contains("\"command\""))
        #expect(body.contains("orrery memory user emit"))
        #expect(body.contains("\"_orrery_managed\""))
    }

    @Test("install is idempotent")
    func installIdempotent() throws {
        let installer = ClaudeHookInstaller()
        try installer.install(at: tmpDir)
        try installer.install(at: tmpDir)
        let settings = tmpDir.appendingPathComponent("settings.json")
        let data = try Data(contentsOf: settings)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]
        let sessionStart = hooks["SessionStart"] as! [[String: Any]]
        let firstMatcher = sessionStart[0]
        let entries = firstMatcher["hooks"] as! [[String: Any]]
        let managed = entries.filter { ($0["_orrery_managed"] as? Bool) == true }
        #expect(managed.count == 1)
    }

    @Test("install preserves foreign hook entries")
    func installPreservesForeign() throws {
        let settings = tmpDir.appendingPathComponent("settings.json")
        let foreign: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    [
                        "matcher": "*",
                        "hooks": [
                            ["type": "command", "command": "echo something-else"]
                        ]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: foreign, options: [.prettyPrinted])
        try data.write(to: settings)

        try ClaudeHookInstaller().install(at: tmpDir)

        let updated = try JSONSerialization.jsonObject(with: try Data(contentsOf: settings)) as! [String: Any]
        let hooks = updated["hooks"] as! [String: Any]
        let sessionStart = hooks["SessionStart"] as! [[String: Any]]
        let entries = sessionStart[0]["hooks"] as! [[String: Any]]
        #expect(entries.count == 2)
        let commands = entries.compactMap { $0["command"] as? String }
        #expect(commands.contains("echo something-else"))
        #expect(commands.contains("orrery memory user emit"))
    }

    @Test("remove only deletes _orrery_managed entries")
    func removeKeepsForeign() throws {
        let settings = tmpDir.appendingPathComponent("settings.json")
        try ClaudeHookInstaller().install(at: tmpDir)
        // Inject a foreign entry next to ours
        var json = try JSONSerialization.jsonObject(with: try Data(contentsOf: settings)) as! [String: Any]
        var hooks = json["hooks"] as! [String: Any]
        var sessionStart = hooks["SessionStart"] as! [[String: Any]]
        var entries = sessionStart[0]["hooks"] as! [[String: Any]]
        entries.append(["type": "command", "command": "echo foreign"])
        sessionStart[0]["hooks"] = entries
        hooks["SessionStart"] = sessionStart
        json["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
            .write(to: settings)

        try ClaudeHookInstaller().remove(at: tmpDir)

        let final = try JSONSerialization.jsonObject(with: try Data(contentsOf: settings)) as! [String: Any]
        let finalHooks = final["hooks"] as! [String: Any]
        let finalSessionStart = finalHooks["SessionStart"] as! [[String: Any]]
        let finalEntries = finalSessionStart[0]["hooks"] as! [[String: Any]]
        #expect(finalEntries.count == 1)
        #expect((finalEntries[0]["command"] as? String) == "echo foreign")
    }

    @Test("isInstalled true after install, false after remove")
    func isInstalledStatus() throws {
        let installer = ClaudeHookInstaller()
        #expect(!installer.isInstalled(at: tmpDir))
        try installer.install(at: tmpDir)
        #expect(installer.isInstalled(at: tmpDir))
        try installer.remove(at: tmpDir)
        #expect(!installer.isInstalled(at: tmpDir))
    }
}
