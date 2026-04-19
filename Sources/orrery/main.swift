import Foundation
import OrreryCore
import OrreryThirdParty

LegacyOrbitalMigration.runIfNeeded()
OriginTakeoverBootstrap.runIfNeeded()
OrreryThirdPartyRuntime.register()
OrreryCommand.main()
