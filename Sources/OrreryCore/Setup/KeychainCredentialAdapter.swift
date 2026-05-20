#if os(macOS)
import Foundation

/// macOS Claude 的 CredentialAdapter。
/// Materialize = 把 orrery account 專屬 Keychain item 的 token
/// 複寫到「Claude 依 CLAUDE_CONFIG_DIR 推導出的 service」上。
public struct KeychainCredentialAdapter: CredentialAdapter {
    public init() {}

    public func materialize(
        account: Account,
        targetConfigDir: URL,
        accountStore: AccountStore
    ) throws {
        guard account.tool == .claude else {
            throw Error.wrongTool(got: account.tool)
        }
        guard let orreryService = account.keychainItem else {
            throw Error.missingKeychainItem(accountID: account.id)
        }
        guard ClaudeKeychain.keychainItemExists(service: orreryService) else {
            throw Error.missingCredential(accountID: account.id, service: orreryService)
        }

        // Claude 啟動時用 CLAUDE_CONFIG_DIR 推導它要讀的 Keychain service。
        let targetService = ClaudeKeychain.service(for: targetConfigDir.path)

        guard ClaudeKeychain.copyKeychainItem(from: orreryService, to: targetService) else {
            throw Error.keychainCopyFailed(from: orreryService, to: targetService)
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
