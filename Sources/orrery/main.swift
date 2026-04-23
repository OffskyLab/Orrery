import Foundation
import OrreryCore
import OrreryMagi
import OrreryThirdParty

LegacyOrbitalMigration.runIfNeeded()
OriginTakeoverBootstrap.runIfNeeded()
OrreryThirdPartyRuntime.register()
MagiMCPTools.register(on: MCPServer.self)
OrreryCommand.main()
