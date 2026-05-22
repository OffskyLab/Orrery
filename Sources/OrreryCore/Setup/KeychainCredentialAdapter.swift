#if os(macOS)
import Foundation

/// macOS Claude 的 CredentialAdapter。
/// Materialize = 把 account-pool 專屬 Keychain item 的 token
/// 複寫到「Claude 依 CLAUDE_CONFIG_DIR 推導出的 service」上。
public struct KeychainCredentialAdapter: CredentialAdapter {
    public init() {}

    public func materialize(
        account: Account,
        configDir: String?,
        accountStore: AccountStore
    ) throws {
        // tool 守衛：防止直接以錯誤 tool 的 Account 建構誤用。
        // （CredentialAdapters factory 永遠配對正確，這層是 belt-and-suspenders。）
        guard account.tool == .claude else {
            throw Error.wrongTool(got: account.tool)
        }
        guard let orreryService = account.keychainItem else {
            throw Error.missingKeychainItem(accountID: account.id)
        }
        guard let sourceToken = ClaudeKeychain.password(forService: orreryService) else {
            throw Error.missingCredential(accountID: account.id, service: orreryService)
        }

        // Claude 啟動時用 CLAUDE_CONFIG_DIR 推導它要讀的 Keychain service。
        let targetService = ClaudeKeychain.service(for: configDir)

        // 冪等：target service 已是正確 token 就不重寫。
        if ClaudeKeychain.password(forService: targetService) == sourceToken {
            return
        }

        guard ClaudeKeychain.setPassword(sourceToken, service: targetService) else {
            throw Error.keychainCopyFailed(from: orreryService, to: targetService)
        }
    }

    /// Persist Claude's (possibly refreshed) live credential back into the pool.
    /// Claude rotates its OAuth token on every refresh, writing the new token to
    /// the live Keychain service derived from CLAUDE_CONFIG_DIR — never to the
    /// pool. Without this, the pool snapshot goes stale and switching back to
    /// this account 401s. Copies the LIVE service's token into the pool service.
    public func syncBack(
        account: Account,
        configDir: String?,
        accountStore: AccountStore
    ) throws {
        guard account.tool == .claude else {
            throw Error.wrongTool(got: account.tool)
        }
        guard let poolService = account.keychainItem else {
            throw Error.missingKeychainItem(accountID: account.id)
        }
        let liveService = ClaudeKeychain.service(for: configDir)
        // Claude may not have written a credential (e.g. it errored before login);
        // nothing to sync in that case.
        guard let liveToken = ClaudeKeychain.password(forService: liveService) else {
            return
        }
        // Idempotent: skip the write if the pool already matches.
        if ClaudeKeychain.password(forService: poolService) == liveToken {
            return
        }
        guard ClaudeKeychain.setPassword(liveToken, service: poolService) else {
            throw Error.keychainCopyFailed(from: liveService, to: poolService)
        }
    }

    public enum Error: Swift.Error {
        case wrongTool(got: Tool)
        case missingKeychainItem(accountID: String)
        case missingCredential(accountID: String, service: String)
        case keychainCopyFailed(from: String, to: String)
    }
}
#endif
