import ArgumentParser
import Foundation

/// Opt-in migration of all claude, codex, and gemini pool accounts from the
/// legacy layout to the v3.1 per-account-dir layout.
///
/// Idempotent. Doesn't remove any legacy state — the materialize/syncBack
/// path continues to work for accounts that haven't been migrated yet.
public struct MigrateToV31Command: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "migrate-to-v3.1",
        abstract: L10n.Migrate.abstract
    )

    public init() {}

    public func run() throws {
        let acctStore = AccountStore.default
        let envStore = EnvironmentStore.default

        var migrated = 0
        var alreadyV31 = 0
        var total = 0

        // Claude: full migration via ClaudeAccountMigration (identity/shared
        // JSON split + account-dir symlinks).
        let claudeAccounts = try acctStore.list(tool: .claude)
        let claudeManager = try AccountDirectoryRuntime.manager(for: .claude)
        for acct in claudeAccounts {
            let poolDir = acctStore.accountDir(id: acct.id, tool: .claude)
            let identityURL = ClaudeJsonMerge.identityFileURL(accountDir: poolDir)
            let wasV31 = FileManager.default.fileExists(atPath: identityURL.path)
                && claudeManager.verifySymlinks(
                    account: acct, accountStore: acctStore, environmentStore: envStore) == .ok

            try ClaudeAccountMigration.migrateAccount(
                acct, accountStore: acctStore, environmentStore: envStore)

            report(tool: .claude, name: acct.displayName, wasV31: wasV31,
                   migrated: &migrated, alreadyV31: &alreadyV31)
        }
        total += claudeAccounts.count

        // Codex and gemini: prepareDirectory alone is the whole migration —
        // their credential files (auth.json / oauth_creds.json) are already
        // pure credential files (materialized by CredentialAdapters), nothing
        // to split like claude's .claude.json.
        for tool in [Tool.codex, .gemini] {
            let accounts = try acctStore.list(tool: tool)
            let manager = try AccountDirectoryRuntime.manager(for: tool)
            for acct in accounts {
                let wasV31 = manager.verifySymlinks(
                    account: acct, accountStore: acctStore, environmentStore: envStore) == .ok

                try manager.prepareDirectory(
                    account: acct, accountStore: acctStore, environmentStore: envStore)

                report(tool: tool, name: acct.displayName, wasV31: wasV31,
                       migrated: &migrated, alreadyV31: &alreadyV31)
            }
            total += accounts.count
        }

        print("")
        print("Done. Migrated \(migrated), already-v3.1 \(alreadyV31), total accounts \(total).")
    }

    private func report(
        tool: Tool, name: String, wasV31: Bool,
        migrated: inout Int, alreadyV31: inout Int
    ) {
        if wasV31 {
            print("Skipped (already v3.1): \(tool.rawValue)/\(name)")
            alreadyV31 += 1
        } else {
            print("Migrated: \(tool.rawValue)/\(name)")
            migrated += 1
        }
    }
}
