import Foundation

public enum AccountLoginFlow {
    /// 觸發工具登入並把憑證匯入 account pool。
    /// 第一版為 stub；真正的登入自動化在後續 task 補上。
    public static func run(account: Account) throws {
        // Stub here is intentional; a later task replaces this with the real login flow.
        print("[orrery] account '\(account.displayName)' (\(account.tool.rawValue)) registered.")
        print("[orrery] Login automation not yet wired up; populate the account credential manually or via migration for now.")
    }
}
