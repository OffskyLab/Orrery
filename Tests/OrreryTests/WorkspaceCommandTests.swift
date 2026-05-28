import ArgumentParser
import Foundation
import Testing
@testable import OrreryCore

@Suite("WorkspaceCommand")
struct WorkspaceCommandTests {

    @Test("WorkspaceCommand runs with list subcommand")
    func workspaceListRuns() throws {
        try withIsolatedHome {
            // The list subcommand should work when invoked through WorkspaceCommand.
            #expect(throws: Never.self) {
                var list = try SandboxCommand.List.parse([])
                try list.run()
            }
        }
    }

    @Test("WorkspaceCommand declares subcommands matching SandboxCommand")
    func sameSubcommands() {
        let workspaceSubs = WorkspaceCommand.configuration.subcommands.map { String(describing: $0) }
        let sandboxSubs = SandboxCommand.configuration.subcommands.map { String(describing: $0) }
        #expect(workspaceSubs == sandboxSubs)
    }
}
