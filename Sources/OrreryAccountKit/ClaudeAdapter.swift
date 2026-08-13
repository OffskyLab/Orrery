import Foundation
import OrreryCore

/// Claude's `ToolAccountManaging` implementation. Same blocklist and base
/// symlink set as the original v3.1 `ClaudeAccountDirectory` — behavior is
/// unchanged — except workspace paths now resolve through
/// `EnvironmentStore.toolConfigDir` (UUID-keyed) instead of the old
/// `claudeWorkspaceDir` (literal display name), which is what every other
/// consumer (session discovery, `orrery run`, workspace CRUD, codex/gemini)
/// already used. Named workspaces used to get two independent `claude/`
/// directory trees under one label; this fixes that split at the source.
public struct ClaudeAdapter: ToolAccountManaging {
    public let tool: Tool = .claude
    public let exportEnvVarName = "CLAUDE_CONFIG_DIR"

    /// Never shared into the workspace, even though everything else in the
    /// account dir is (blocklist policy).
    public static let privateSubdirs: Set<String> = ["backups", "cache", "cc-statusline"]

    /// Ensured to exist (as symlinks) even for a fresh account, beyond
    /// whatever `mirrorWorkspaceDirsToAccount` gap-fills organically.
    public static let baseSharedSubdirs: [String] = ["projects", "memory", "agents", "commands", "todos"]

    public static let policy = AccountDirSharingPolicy.blocklist(privateSubdirs)

    public init() {}

    public enum Error: Swift.Error, LocalizedError {
        case wrongTool(got: Tool)

        public var errorDescription: String? {
            switch self {
            case .wrongTool(let t):
                return "ClaudeAdapter only handles claude accounts, got \(t.rawValue)."
            }
        }
    }

    public func prepareDirectory(
        account: Account,
        accountStore: AccountStore,
        environmentStore: EnvironmentStore
    ) throws {
        guard account.tool == .claude else {
            throw Error.wrongTool(got: account.tool)
        }

        let fm = FileManager.default
        let acctDir = accountStore.accountDir(id: account.id, tool: .claude)
        let wsDir = environmentStore.toolConfigDir(tool: .claude, environment: account.workspace)

        try fm.createDirectory(at: acctDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: wsDir, withIntermediateDirectories: true)

        let linkWarnings = AccountDirLinker.linkAccountDirsToWorkspace(
            accountDir: acctDir, workspaceDir: wsDir, policy: Self.policy)
        for w in linkWarnings {
            FileHandle.standardError.write(
                Data("orrery: link-workspace: \(w)\n".utf8))
        }

        // Ensure the standard base set exists as symlinks even on a fresh
        // account where claude hasn't created those dirs yet (nothing to move).
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
                if isRealDir(link, fm: fm) {
                    // Couldn't fully migrate this real dir (warning already
                    // emitted above). Leave the data in place and visible —
                    // never hide it in backups — a later run retries the merge.
                    continue
                }
                // A stray plain file sits at a base path — back it up, then
                // symlink so the account self-heals instead of staying stuck.
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
        guard account.tool == .claude else { return .notApplicable }

        let fm = FileManager.default
        let acctDir = accountStore.accountDir(id: account.id, tool: .claude)
        let expectedTargetBase = environmentStore.toolConfigDir(tool: .claude, environment: account.workspace)

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
