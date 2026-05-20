import Foundation

/// 抽象「啟動工具前讓某個 account 的憑證對工具可見」的行為。
/// 不同 (工具, 平台) 組合用不同實作。
public protocol CredentialAdapter: Sendable {
    /// Materialize：把 account 的憑證放到工具預期讀取的位置。
    /// 冪等。如果已經就定位，不重做。
    func materialize(
        account: Account,
        targetConfigDir: URL,
        accountStore: AccountStore
    ) throws

    /// 從 account 池讀回顯示用的帳號資訊（email/plan 等），失敗回 nil。
    func accountInfo(account: Account, accountStore: AccountStore) -> ToolAuth.AccountInfo?
}
