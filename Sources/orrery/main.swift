import ArgumentParser
import Foundation
import OrreryCore
import OrreryThirdParty

@MainActor
private func runOrreryMain() throws {
    LegacyOrbitalMigration.runIfNeeded()
    // Takeover MUST run before AccountMigration: takeover populates ~/.orrery/origin/
    // with the user's real credentials (via symlinks from ~/.claude, ~/.codex, ~/.gemini).
    // Migration's "nothing to migrate" check looks at ~/.orrery/origin/. If migration
    // ran first on an empty ~/.orrery/, it would write the .migration-v3 flag and exit,
    // causing real credentials moved in later by takeover to be silently skipped forever.
    OriginTakeoverBootstrap.runIfNeeded()
    // v2→v3 account-pool migration. Runs after the orbital→orrery move (so any
    // freshly-migrated envs are included) and after origin takeover (so any origin-
    // resident credentials are visible). A throw here (e.g. backup failure or an
    // active phantom session) aborts the whole invocation — intentional: it is
    // safer to stop than to migrate credentials unsafely.
    try AccountMigration.runIfNeeded(homeURL: orreryHomeURL())
    // One-shot retroactive backfill: populate email/plan on accounts that were
    // created (via v3 migration or manual `account add`) before those fields
    // were stored on the `Account` model. Best-effort, never throws.
    AccountMigration.runInfoBackfillIfNeeded(homeURL: orreryHomeURL())
    // One-shot Claude oauthAccount-snapshot backfill: pre-v3.0.4 the pool
    // never snapshotted `.claude.json`'s oauthAccount, so cached email/plan
    // could be from different identities. Capture snapshots from referencing
    // envs where possible and re-derive cached fields.
    AccountMigration.runClaudeOAuthSnapshotBackfillIfNeeded(homeURL: orreryHomeURL())
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
