import Testing
import ArgumentParser
@testable import OrreryCore

@Suite("MemoryCommand structure")
struct MemoryCommandStructureTests {

    @Test("MemoryCommand has project and user subcommand groups")
    func subgroupsPresent() {
        let names = MemoryCommand.configuration.subcommands.map { $0._commandName }
        #expect(names.contains("project"))
        #expect(names.contains("user"))
    }

    @Test("ProjectMemoryCommand exposes info/export/isolate/share/storage")
    func projectSubcommandsExist() {
        let names = MemoryCommand.ProjectSubcommand.configuration.subcommands.map { $0._commandName }
        for expected in ["info", "export", "isolate", "share", "storage"] {
            #expect(names.contains(expected), "missing subcommand: \(expected)")
        }
    }

    @Test("orrery memory no longer has top-level info subcommand")
    func topLevelFlatRemoved() {
        let names = MemoryCommand.configuration.subcommands.map { $0._commandName }
        #expect(!names.contains("info"))
        #expect(!names.contains("isolate"))
        #expect(!names.contains("share"))
        #expect(!names.contains("storage"))
        #expect(!names.contains("export"))
    }
}

// Helper: surfaces the configured command name for assertions.
extension ParsableCommand {
    static var _commandName: String { configuration.commandName ?? "\(self)".lowercased() }
}
