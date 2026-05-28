import ArgumentParser
import Foundation

/// Opt-in migration of all claude pool accounts from v3.0.4 layout to v3.1
/// per-account-dir layout.
///
/// Idempotent. Doesn't remove any v3.0.4 state — the materialize/syncBack
/// path continues to work for accounts that haven't been migrated yet (Plan 4
/// removes the legacy path once v3.1 is the default).
public struct MigrateToV31Command: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "migrate-to-v3.1",
        abstract: "Bring claude pool accounts up to the v3.1 per-account-dir layout (idempotent, additive)."
    )

    public init() {}

    public func run() throws {
        let acctStore = AccountStore.default
        let envStore = EnvironmentStore.default

        let claudeAccounts = (try? acctStore.list(tool: .claude)) ?? []
        var migrated = 0
        var alreadyV31 = 0

        for acct in claudeAccounts {
            let poolDir = acctStore.accountDir(id: acct.id, tool: .claude)
            let identityURL = ClaudeJsonMerge.identityFileURL(accountDir: poolDir)
            let wasV31 = FileManager.default.fileExists(atPath: identityURL.path)
                && ClaudeAccountDirectory.verifySymlinks(
                    account: acct, accountStore: acctStore, environmentStore: envStore) == .ok

            try ClaudeAccountMigration.migrateAccount(
                acct, accountStore: acctStore, environmentStore: envStore)

            if wasV31 {
                print("Skipped (already v3.1): \(acct.displayName)")
                alreadyV31 += 1
            } else {
                print("Migrated: \(acct.displayName)")
                migrated += 1
            }
        }

        print("")
        print("Done. Migrated \(migrated), already-v3.1 \(alreadyV31), total claude accounts \(claudeAccounts.count).")
    }
}
