import ArgumentParser
import Foundation
import OrreryCore
import OrreryThirdParty

private func runOrreryMain() throws {
    LegacyOrbitalMigration.runIfNeeded()
    OriginTakeoverBootstrap.runIfNeeded()
    OrreryThirdPartyRuntime.register()

    let firstArgument = CommandLine.arguments.dropFirst().first

    if firstArgument == "mcp-server" {
        try MagiMCPTools.register(on: MCPServer.self)
    }

    if let arg = firstArgument, ["magi", "spec", "spec-run", "_spec-finalize"].contains(arg) {
        let binary = try MagiSidecar.resolve()
        try MagiSidecar.dispatch(binary, args: Array(CommandLine.arguments.dropFirst()))
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
