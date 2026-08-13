import Foundation
import OrreryCore

/// Codex's `ToolAccountManaging` implementation. Uses an allowlist rather
/// than claude's blocklist: most of codex's config dir is runtime noise
/// (sqlite state, logs, tmp, ipc, caches) rather than config, so sharing
/// everything-not-blocked would leak lock-bearing state across accounts
/// pinned to the same workspace. Only real capabilities travel with the
/// workspace; everything else — credentials, codex's own memory store,
/// history, runtime state — stays private to the account.
public struct CodexAdapter: ToolAccountManaging {
    public let tool: Tool = .codex
    public let exportEnvVarName = "CODEX_HOME"

    /// The only names shared into the pinned workspace.
    public static let baseSharedSubdirs: [String] = ["skills", "plugins", "rules", "sessions"]

    public static let policy = AccountDirSharingPolicy.allowlist(Set(baseSharedSubdirs))

    public init() {}

    public enum Error: Swift.Error, LocalizedError {
        case wrongTool(got: Tool)

        public var errorDescription: String? {
            switch self {
            case .wrongTool(let t):
                return "CodexAdapter only handles codex accounts, got \(t.rawValue)."
            }
        }
    }

    public func prepareDirectory(
        account: Account,
        accountStore: AccountStore,
        environmentStore: EnvironmentStore
    ) throws {
        guard account.tool == .codex else {
            throw Error.wrongTool(got: account.tool)
        }

        let fm = FileManager.default
        let acctDir = accountStore.accountDir(id: account.id, tool: .codex)
        let wsDir = environmentStore.toolConfigDir(tool: .codex, environment: account.workspace)

        try fm.createDirectory(at: acctDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: wsDir, withIntermediateDirectories: true)

        let linkWarnings = AccountDirLinker.linkAccountDirsToWorkspace(
            accountDir: acctDir, workspaceDir: wsDir, policy: Self.policy)
        for w in linkWarnings {
            FileHandle.standardError.write(Data("orrery: link-workspace: \(w)\n".utf8))
        }

        for sub in Self.baseSharedSubdirs {
            let target = wsDir.appendingPathComponent(sub)
            // The workspace side must be a real directory. A dangling symlink
            // can already be sitting there (e.g. a leftover from an isolation
            // test whose ORRERY_HOME no longer exists) — createDirectory(at:)
            // fails with an I/O error through a broken symlink, so clear it
            // first. A real (non-empty) directory is left untouched.
            if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
                try fm.removeItem(at: target)
            }
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            let link = acctDir.appendingPathComponent(sub)
            if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                if dest != target.path {
                    try fm.removeItem(at: link)
                    try fm.createSymbolicLink(at: link, withDestinationURL: target)
                }
            } else if fm.fileExists(atPath: link.path) {
                if isRealDir(link, fm: fm) { continue }
                let backup = acctDir
                    .appendingPathComponent("backups")
                    .appendingPathComponent("premerge-\(premergeStamp())")
                    .appendingPathComponent(sub)
                try fm.createDirectory(
                    at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: link, to: backup)
                try fm.createSymbolicLink(at: link, withDestinationURL: target)
            } else {
                try fm.createSymbolicLink(at: link, withDestinationURL: target)
            }
        }
    }

    public func verifySymlinks(
        account: Account,
        accountStore: AccountStore,
        environmentStore: EnvironmentStore
    ) -> AccountDirSymlinkStatus {
        guard account.tool == .codex else { return .notApplicable }

        let fm = FileManager.default
        let acctDir = accountStore.accountDir(id: account.id, tool: .codex)
        let expectedTargetBase = environmentStore.toolConfigDir(tool: .codex, environment: account.workspace)

        var sawMismatch = false
        for sub in Self.baseSharedSubdirs {
            let linkPath = acctDir.appendingPathComponent(sub).path
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: linkPath) else {
                return .missing
            }
            if !fm.fileExists(atPath: dest) {
                return .missing
            }
            let expected = expectedTargetBase.appendingPathComponent(sub).path
            if dest != expected { sawMismatch = true }
        }
        return sawMismatch ? .mismatch : .ok
    }

    @discardableResult
    public func mirrorWorkspaceDirsToAccount(accountDir: URL, workspaceDir: URL) -> [String] {
        AccountDirLinker.mirrorWorkspaceDirsToAccount(
            accountDir: accountDir, workspaceDir: workspaceDir, policy: Self.policy)
    }

    private func isRealDir(_ url: URL, fm: FileManager) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return (v?.isDirectory ?? false) && !(v?.isSymbolicLink ?? false)
    }

    private func premergeStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: Date())
    }
}
