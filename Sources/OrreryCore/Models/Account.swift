import Foundation

public typealias AccountID = String

/// 跨 env 共用的工具憑證 pool 中的一筆。
/// 持久化於 `~/.orrery/accounts/<tool>/<id>/metadata.json`。
public struct Account: Codable, Sendable, Equatable {
    public let id: AccountID
    public var tool: Tool
    public var displayName: String
    public let createdAt: Date

    /// macOS Claude 專用：對應的 Keychain item 名稱。
    /// 其他工具 / 平台組合為 nil。
    public var keychainItem: String?

    public init(
        id: AccountID = UUID().uuidString,
        tool: Tool,
        displayName: String,
        createdAt: Date = Date(),
        keychainItem: String? = nil
    ) {
        self.id = id
        self.tool = tool
        self.displayName = displayName
        self.createdAt = createdAt
        self.keychainItem = keychainItem
    }
}
