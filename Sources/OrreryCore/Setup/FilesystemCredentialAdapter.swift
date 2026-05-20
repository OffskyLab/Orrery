import Foundation

public struct FilesystemCredentialAdapter: CredentialAdapter {
    public enum Error: Swift.Error {
        case missingCredential(tool: Tool, accountID: String, expectedPath: String)
    }

    let tool: Tool

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
        configDir: String?,
        accountStore: AccountStore
    ) throws {
        let targetConfigDir: URL = configDir.map { URL(fileURLWithPath: $0) } ?? tool.defaultConfigDir
        let fm = FileManager.default
        let source = accountStore.accountDir(id: account.id, tool: tool)
            .appendingPathComponent(credentialFileName)
        let target = targetConfigDir.appendingPathComponent(credentialFileName)

        // 來源憑證必須存在於 pool。否則 materialize 沒有意義，
        // clear error 勝過建立 dangling symlink 讓工具稍後爆出無關錯誤。
        guard fm.fileExists(atPath: source.path) else {
            throw Error.missingCredential(
                tool: tool, accountID: account.id, expectedPath: source.path
            )
        }

        // 冪等：若 symlink 已指向正確位置，直接 return。
        if let existing = try? fm.destinationOfSymbolicLink(atPath: target.path),
           existing == source.path {
            return
        }

        // 移除任何既有的 target（regular file 或舊 symlink，含 broken symlink）。
        if fm.fileExists(atPath: target.path)
            || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
            try fm.removeItem(at: target)
        }

        try fm.createDirectory(at: targetConfigDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: target, withDestinationURL: source)
    }
}
