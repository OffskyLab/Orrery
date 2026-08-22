import Foundation
import Testing
@testable import OrreryCore

@Suite("MCPSetupCommand.installSlashCommands")
struct MCPSetupCommandTests {

    @Test("generated /orrery:delegate command uses --account, not the removed -e flag")
    func delegateSlashCommandUsesAccountFlag() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPSetupCommandTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try MCPSetupCommand.SetupSubcommand.installSlashCommands(projectDir: tempDir.path)

        let delegateMd = tempDir
            .appendingPathComponent(".claude")
            .appendingPathComponent("commands")
            .appendingPathComponent("orrery:delegate.md")
        let content = try String(contentsOf: delegateMd, encoding: .utf8)

        #expect(content.contains("orrery delegate --account <environment>"))
        #expect(!content.contains("orrery delegate -e <environment>"))
    }
}
