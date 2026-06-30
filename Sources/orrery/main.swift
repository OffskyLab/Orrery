import ArgumentParser
import Foundation
import OrreryCore
import OrreryThirdParty

@MainActor
private func runOrreryMain() async throws {
    LegacyOrbitalMigration.runIfNeeded()
    // Phase A of the workspace-layout migration: relocate the v3.0.x tree to the
    // unified workspaces/ layout BEFORE takeover, so takeover sees the new paths.
    AccountMigration.runWorkspaceStructureRelocationIfNeeded(homeURL: orreryHomeURL())
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
    // Phase B of the workspace-layout migration: rebuild each claude account's
    // workspace symlinks against the unified layout (needs the account pool).
    AccountMigration.runWorkspaceAccountSymlinksIfNeeded(homeURL: orreryHomeURL())
    // Phase C: fold the takeover-captured workspace settings into each account
    // dir and point ~/.claude at the origin account dir, so origin reads the same
    // account dir that `orrery use` selects (statusline + settings consistent).
    AccountMigration.runAccountConfigConsolidationIfNeeded(homeURL: orreryHomeURL())
    // Phase D: repair installs upgraded from older/broken versions where the
    // origin workspace lost its account pins (no active default; ~/.claude not
    // repointed). Re-pins the "origin" account per tool, then consolidates +
    // repoints. Flag-guarded; runs once on affected machines.
    AccountMigration.runOriginPinRepairIfNeeded(homeURL: orreryHomeURL())
    OrreryThirdPartyRuntime.register()

    let firstArgument = CommandLine.arguments.dropFirst().first

    if firstArgument == "mcp-server" {
        // Best-effort: register sidecar-forwarded tools if sidecar is
        // available; otherwise skip and let built-in tools serve alone.
        MagiMCPTools.register(on: MCPServer.self)
        // Launch MCP server directly without going through ArgumentParser
        // (workaround for AsyncParsableCommand nested in AsyncParsableCommand issue)
        await MCPServer.run()
        Foundation.exit(0)
    }

    if let arg = firstArgument, ["magi", "spec", "spec-run", "_spec-finalize"].contains(arg) {
        let binary = try MagiSidecar.resolve()
        try MagiSidecar.dispatch(binary, args: Array(CommandLine.arguments.dropFirst()))
        Foundation.exit(0)
    }

    await OrreryCommand.main()
}

// Only keep RunLoop alive for mcp-server; other commands should exit after completion
let firstArgument = CommandLine.arguments.dropFirst().first
let isMCPServer = firstArgument == "mcp-server"

Task { @MainActor in
    do {
        try await runOrreryMain()
        if !isMCPServer {
            Foundation.exit(0)
        }
    } catch let exitCode as ExitCode {
        Foundation.exit(exitCode.rawValue)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        Foundation.exit(1)
    }
}

if isMCPServer {
    RunLoop.main.run()
} else {
    // For non-MCP commands, wait for the task to complete and exit
    dispatchMain()
}
