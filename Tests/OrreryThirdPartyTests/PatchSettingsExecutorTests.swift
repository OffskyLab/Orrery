import Testing
import Foundation
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("PatchSettingsExecutor")
struct PatchSettingsExecutorTests {
    private func tempClaudeDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-patch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("missing file → writes new with full patch")
    func missingFileBootstrap() throws {
        let claudeDir = try tempClaudeDir()
        defer { try? FileManager.default.removeItem(at: claudeDir) }
        let patch: JSONValue = .object(["statusLine": .object(["type": .string("command")])])

        let record = try PatchSettingsExecutor.apply(
            .patchSettings(file: "settings.json", patch: patch),
            claudeDir: claudeDir,
            placeholders: [:]
        )
        #expect(record.file == "settings.json")
        let data = try Data(contentsOf: claudeDir.appendingPathComponent("settings.json"))
        let parsed = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(parsed == patch)
    }

    @Test("substitutes <CLAUDE_DIR> placeholder")
    func substitutesPlaceholder() throws {
        let claudeDir = try tempClaudeDir()
        defer { try? FileManager.default.removeItem(at: claudeDir) }
        let abs = claudeDir.path
        let patch: JSONValue = .object([
            "statusLine": .object(["command": .string("node <CLAUDE_DIR>/x.js")])
        ])
        _ = try PatchSettingsExecutor.apply(
            .patchSettings(file: "settings.json", patch: patch),
            claudeDir: claudeDir,
            placeholders: ["<CLAUDE_DIR>": abs]
        )
        let data = try Data(contentsOf: claudeDir.appendingPathComponent("settings.json"))
        let parsed = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let o) = parsed,
              case .object(let sl) = o["statusLine"],
              case .string(let cmd) = sl["command"] else {
            Issue.record("shape mismatch"); return
        }
        #expect(cmd == "node \(abs)/x.js")
    }

    @Test("rollback restores original bytes")
    func rollbackRestoresFile() throws {
        let claudeDir = try tempClaudeDir()
        defer { try? FileManager.default.removeItem(at: claudeDir) }
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        let original = Data(#"{"model":"old"}"#.utf8)
        try original.write(to: settingsURL)

        let patch: JSONValue = .object(["model": .string("new")])
        let record = try PatchSettingsExecutor.apply(
            .patchSettings(file: "settings.json", patch: patch),
            claudeDir: claudeDir,
            placeholders: [:]
        )
        try PatchSettingsExecutor.rollback(record: record, claudeDir: claudeDir)
        let afterRollback = try Data(contentsOf: settingsURL)
        let parsedOriginal = try JSONDecoder().decode(JSONValue.self, from: original)
        let parsedAfter = try JSONDecoder().decode(JSONValue.self, from: afterRollback)
        #expect(parsedOriginal == parsedAfter)
    }
}
