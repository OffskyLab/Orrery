import Foundation

/// 抽象「啟動工具前讓某個 account 的憑證對工具可見」的行為。
/// 不同 (工具, 平台) 組合用不同實作。
public protocol CredentialAdapter: Sendable {
    /// Materialize：把 account 的憑證放到工具預期讀取的位置。
    /// configDir = 工具執行時的 config 目錄；nil 代表工具預設位置（origin，env var 未設）。
    /// 冪等。如果已經就定位，不重做。
    func materialize(
        account: Account,
        configDir: String?,
        accountStore: AccountStore
    ) throws
}

/// Factory：依工具 + 平台選擇 CredentialAdapter 實作。
public enum CredentialAdapters {
    public static func adapter(for tool: Tool) -> any CredentialAdapter {
        switch tool {
        case .claude:
            #if os(macOS)
            return KeychainCredentialAdapter()
            #else
            return FilesystemCredentialAdapter(tool: .claude)
            #endif
        case .codex:
            return FilesystemCredentialAdapter(tool: .codex)
        case .gemini:
            return FilesystemCredentialAdapter(tool: .gemini)
        }
    }
}
