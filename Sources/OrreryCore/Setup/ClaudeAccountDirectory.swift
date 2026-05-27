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
        precondition(account.tool == .claude,
            "ClaudeAccountDirectory only handles claude accounts")

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

            // Anything else at the path — symlink to elsewhere, real dir,
            // or file — gets removed first.
            if fm.fileExists(atPath: linkPath.path)
                || (try? fm.destinationOfSymbolicLink(atPath: linkPath.path)) != nil {
                try fm.removeItem(at: linkPath)
            }

            try fm.createSymbolicLink(at: linkPath, withDestinationURL: targetPath)
        }
    }
}
