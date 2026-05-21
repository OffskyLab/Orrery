import ArgumentParser
import Foundation
import OrreryCore
import OrreryThirdParty

@MainActor
private func runOrreryMain() throws {
    LegacyOrbitalMigration.runIfNeeded()
    // v2→v3 account-pool migration. Runs after the orbital→orrery move (so any
    // freshly-migrated envs are included) and before origin takeover / any
    // subcommand touches the stores. A throw here (e.g. backup failure or an
    // active phantom session) aborts the whole invocation — intentional: it is
    // safer to stop than to migrate credentials unsafely.
    try AccountMigration.runIfNeeded(homeURL: orreryHomeURL())
    // One-shot retroactive backfill: populate email/plan on accounts that were
    // created (via v3 migration or manual `account add`) before those fields
    // were stored on the `Account` model. Best-effort, never throws.
    AccountMigration.runInfoBackfillIfNeeded(homeURL: orreryHomeURL())
    OriginTakeoverBootstrap.runIfNeeded()
    OrreryThirdPartyRuntime.register()

    let firstArgument = CommandLine.arguments.dropFirst().first

    if firstArgument == "mcp-server" {
        // Best-effort: register sidecar-forwarded tools if sidecar is
        // available; otherwise skip and let built-in tools serve alone.
        MagiMCPTools.register(on: MCPServer.self)
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
