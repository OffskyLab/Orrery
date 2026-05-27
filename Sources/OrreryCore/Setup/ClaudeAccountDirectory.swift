import Foundation

/// v3.1: helpers for managing the per-account Claude config dir
/// at `<homeURL>/accounts/claude/<id>/`. Each account dir is its own
/// `CLAUDE_CONFIG_DIR` and contains:
///
/// - `.claude.json`, `.credentials.json` (or macOS keychain), `settings.json`,
///   `history.jsonl`, `backups/`, `cache/`, `plugins/` — per-account files
///   that claude creates and owns
/// - `projects/`, `memory/`, `agents/`, `commands/`, `todos/` — symlinks to
///   the pinned workspace's `claude-workspace/<sub>` directories, so multiple
///   accounts pinned to the same workspace share these
///
/// Pin changes go through `prepareDirectory` (idempotent — repointing 5 symlinks
/// is the only filesystem change).
public enum ClaudeAccountDirectory {

    /// Subdirs that are workspace-shared (symlinked).
    public static let sharedSubdirs: [String] = [
        "projects", "memory", "agents", "commands", "todos"
    ]

    public enum Error: Swift.Error, LocalizedError {
        case wrongTool(got: Tool)
        case existingDirectoryAtSymlinkPath(URL)

        public var errorDescription: String? {
            switch self {
            case .wrongTool(let t):
                return "ClaudeAccountDirectory only handles claude accounts, got \(t.rawValue)."
            case .existingDirectoryAtSymlinkPath(let url):
                return "Refusing to overwrite real directory at \(url.path) — move or remove its contents manually, then re-run."
            }
        }
    }

    /// Create (or repair) the account dir with symlinks pointing at the
    /// workspace from `account.workspace`. Idempotent.
    ///
    /// Throws on filesystem failures (permission, missing parent, etc.) so the
    /// caller can surface a clear error to the user.
    public static func prepareDirectory(
        account: Account,
        accountStore: AccountStore,
        environmentStore: EnvironmentStore
    ) throws {
        guard account.tool == .claude else {
            throw Error.wrongTool(got: account.tool)
        }

        let fm = FileManager.default
        let acctDir = accountStore.accountDir(id: account.id, tool: .claude)
        let wsDir = environmentStore.claudeWorkspaceDir(workspace: account.workspace)

        // 1. Ensure account dir exists.
        try fm.createDirectory(at: acctDir, withIntermediateDirectories: true)

        // 2. Ensure workspace's claude-workspace dir exists with all subdirs.
        try fm.createDirectory(at: wsDir, withIntermediateDirectories: true)
        for sub in sharedSubdirs {
            try fm.createDirectory(
                at: wsDir.appendingPathComponent(sub),
                withIntermediateDirectories: true
            )
        }

        // 3. Create or repoint each symlink.
        for sub in sharedSubdirs {
            let linkPath = acctDir.appendingPathComponent(sub)
            let targetPath = wsDir.appendingPathComponent(sub)

            // Already a symlink pointing at the right place? Skip.
            if let existing = try? fm.destinationOfSymbolicLink(atPath: linkPath.path),
               existing == targetPath.path {
                continue
            }

            // Different symlink (pointing somewhere else, or broken) — safe to replace.
            if (try? fm.destinationOfSymbolicLink(atPath: linkPath.path)) != nil {
                try fm.removeItem(at: linkPath)
                try fm.createSymbolicLink(at: linkPath, withDestinationURL: targetPath)
                continue
            }

            // Path exists but is NOT a symlink — refuse to clobber it. Could
            // be a real directory the user populated or claude wrote into;
            // silently deleting would be a data-loss footgun.
            if fm.fileExists(atPath: linkPath.path) {
                throw Error.existingDirectoryAtSymlinkPath(linkPath)
            }

            // Path doesn't exist — fresh symlink.
            try fm.createSymbolicLink(at: linkPath, withDestinationURL: targetPath)
        }
    }

    /// Result of checking that an account's symlinks point at its current
    /// workspace.
    public enum SymlinkStatus: Equatable {
        /// All 5 symlinks present, pointing at the expected workspace dir, and
        /// their targets exist on disk.
        case ok
        /// One or more symlinks are missing, OR present but their target dir
        /// doesn't exist (broken symlink). `prepareDirectory` repairs both.
        case missing
        /// One or more symlinks point at a different workspace than
        /// `account.workspace` (likely because `workspace` was changed but
        /// `prepareDirectory` wasn't re-run).
        case mismatch
        /// The account isn't a claude account — this helper doesn't apply.
        /// Distinct from `.missing` so callers don't treat it as "repair me".
        case notApplicable
    }

    /// Check whether the account dir's 5 symlinks all point at the workspace
    /// recorded in `account.workspace` AND their targets exist on disk.
    /// Pure read; doesn't modify anything.
    ///
    /// Returned status is determined in this priority order:
    ///   1. `.notApplicable` — non-claude account, helper doesn't apply
    ///   2. `.missing` — any symlink is absent OR points at a deleted target
    ///   3. `.mismatch` — any symlink points at a different workspace
    ///   4. `.ok` — all 5 symlinks present, correct target, target exists
    ///
    /// `prepareDirectory` is the universal repair action for `.missing` /
    /// `.mismatch`.
    public static func verifySymlinks(
        account: Account,
        accountStore: AccountStore,
        environmentStore: EnvironmentStore
    ) -> SymlinkStatus {
        guard account.tool == .claude else { return .notApplicable }

        let fm = FileManager.default
        let acctDir = accountStore.accountDir(id: account.id, tool: .claude)
        let expectedTargetBase = environmentStore.claudeWorkspaceDir(workspace: account.workspace)

        var sawMismatch = false
        for sub in sharedSubdirs {
            let linkPath = acctDir.appendingPathComponent(sub).path
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: linkPath) else {
                return .missing
            }
            // Broken symlink (target was deleted) is treated as .missing —
            // prepareDirectory will recreate the target dir and the symlink.
            if !fm.fileExists(atPath: dest) {
                return .missing
            }
            let expected = expectedTargetBase.appendingPathComponent(sub).path
            if dest != expected { sawMismatch = true }
        }
        return sawMismatch ? .mismatch : .ok
    }
}
