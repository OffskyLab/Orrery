import Foundation
import OrreryCore
import OrreryMagi
import OrreryThirdParty

LegacyOrbitalMigration.runIfNeeded()
OriginTakeoverBootstrap.runIfNeeded()
OrreryThirdPartyRuntime.register()
MagiMCPTools.register(on: MCPServer.self)

if CommandLine.arguments.dropFirst().first == "magi",
   let binary = MagiSidecar.resolve() {
    do {
        try MagiSidecar.dispatch(binary, args: Array(CommandLine.arguments.dropFirst(2)))
    } catch {
        FileHandle.standardError.write(Data("Failed to launch orrery-magi: \(error)\n".utf8))
        Foundation.exit(1)
    }
}

OrreryCommand.main()
