import Foundation

public struct FilesystemCredentialAdapter: CredentialAdapter {
    public let tool: Tool

    public init(tool: Tool) {
        self.tool = tool
    }

    /// 該工具憑證檔在 account dir / target dir 的相對檔名。
    private var credentialFileName: String {
        switch tool {
        case .codex: return "auth.json"
        case .gemini: return "oauth_creds.json"
        case .claude: return ".credentials.json"  // Linux 路徑
        }
    }

    public func materialize(
        account: Account,
        targetConfigDir: URL,
        accountStore: AccountStore
    ) throws {
        let fm = FileManager.default
        let source = accountStore.accountDir(id: account.id, tool: tool)
            .appendingPathComponent(credentialFileName)
        let target = targetConfigDir.appendingPathComponent(credentialFileName)

        // 冪等：若 symlink 已指向正確位置，直接 return
        if let existing = try? fm.destinationOfSymbolicLink(atPath: target.path),
           existing == source.path {
            return
        }

        // 移除任何既有的 target（檔案或舊 symlink，含 broken symlink）
        if fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
            try fm.removeItem(at: target)
        }

        try fm.createDirectory(at: targetConfigDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: target, withDestinationURL: source)
    }
}
