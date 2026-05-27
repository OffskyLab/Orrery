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
}
