import ArgumentParser
import Foundation
import OrreryCore
import OrreryMagi
import OrreryThirdParty

private func runOrreryMain() throws {
    LegacyOrbitalMigration.runIfNeeded()
    OriginTakeoverBootstrap.runIfNeeded()
    OrreryThirdPartyRuntime.register()

    let firstArgument = CommandLine.arguments.dropFirst().first

    if firstArgument == "mcp-server" {
        try MagiMCPTools.register(on: MCPServer.self)
    }

    if firstArgument == "magi",
       let binary = try MagiSidecar.resolveOrFallback() {
        try MagiSidecar.dispatch(binary, args: Array(CommandLine.arguments.dropFirst(2)))
        Foundation.exit(0)
    }

    OrreryCommand.main()
}

do {
    try runOrreryMain()
} catch let exitCode as ExitCode {
    Foundation.exit(exitCode.rawValue)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    Foundation.exit(1)
}
