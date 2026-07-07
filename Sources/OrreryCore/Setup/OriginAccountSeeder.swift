import Foundation

/// Fresh-user onboarding: after origin takeover moved `~/.<tool>` into the origin
/// workspace, create a brand-new "origin" account per tool that captures the
/// existing login and pins to the origin workspace — so a normal user's account
/// holds only its credential/identity, never the shared data.
///
/// Idempotent + best-effort. Runs for a tool only when it has NO origin account
/// yet (leaving existing installs untouched) and its origin workspace holds a
/// capturable login. A per-tool failure warns and never blocks startup.
public enum OriginAccountSeeder {

    public static func seedOriginAccountsIfNeeded(keychain: KeychainAccess = .live) {
        let acctStore = AccountStore.default
        let envStore = EnvironmentStore.default
        var origin = envStore.loadOriginWorkspace()

        for tool in Tool.allCases {
            guard origin.account(for: tool) == nil else { continue }   // existing → untouched
            let wsToolDir = envStore.originConfigDir(tool: tool)
            guard hasCapturableLogin(tool: tool, workspaceToolDir: wsToolDir, keychain: keychain)
            else { continue }

            do {
                let id = UUID().uuidString
                let account = Account(
                    id: id, tool: tool, displayName: "origin",
                    keychainItem: tool == .claude
                        ? ClaudeKeychain.serviceName(forOrreryAccount: id) : nil,
                    workspace: Workspace.reservedOriginName)
                try acctStore.save(account)

                try captureLogin(account: account, workspaceToolDir: wsToolDir, keychain: keychain)

                origin.setAccount(id, for: tool)
                try envStore.saveOriginWorkspace(origin)

                if tool == .claude {
                    try ClaudeAccountMigration.migrateAccount(
                        account, accountStore: acctStore, environmentStore: envStore)
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "orrery: could not seed origin \(tool.rawValue) account: \(error)\n".utf8))
            }
        }
    }

    private static func hasCapturableLogin(
        tool: Tool, workspaceToolDir: URL, keychain: KeychainAccess
    ) -> Bool {
        switch tool {
        case .codex, .gemini:
            let f = workspaceToolDir.appendingPathComponent(
                FilesystemCredentialAdapter.credentialFileName(for: tool))
            return FileManager.default.fileExists(atPath: f.path)
        case .claude:
            #if os(macOS)
            return keychain.itemExists(ClaudeKeychain.service(for: nil))
            #else
            return FileManager.default.fileExists(
                atPath: workspaceToolDir.appendingPathComponent(".credentials.json").path)
            #endif
        }
    }

    private static func captureLogin(
        account: Account, workspaceToolDir: URL, keychain: KeychainAccess
    ) throws {
        switch account.tool {
        case .codex, .gemini:
            try AccountLoginFlow.importFrom(stagingDir: workspaceToolDir, into: account)
        case .claude:
            #if os(macOS)
            guard let dst = account.keychainItem,
                  keychain.copyItem(ClaudeKeychain.service(for: nil), dst) else {
                throw AccountLoginFlow.LoginError.credentialNotProduced(.claude)
            }
            #else
            try AccountLoginFlow.importFrom(stagingDir: workspaceToolDir, into: account)
            #endif
        }
    }
}
