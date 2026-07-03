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

    /// Top-level subdir names that stay per-account and are NEVER shared to the
    /// workspace. Everything else that is a directory is moved into the pinned
    /// workspace and replaced with a symlink.
    public static let privateSubdirs: Set<String> = ["backups", "cache"]

    /// Move every shareable top-level directory in `accountDir` into
    /// `workspaceDir` and replace it with a symlink pointing there. Shareable =
    /// a directory (or existing symlink) whose name is not dot-prefixed and not
    /// in `privateSubdirs`. Top-level files are never touched.
    ///
    /// Merge is a union with the workspace winning: files present only in the
    /// account move over; on a same-path conflict the workspace copy is kept and
    /// the account copy is moved to `backups/premerge-<timestamp>/`.
    ///
    /// Best-effort: never throws. Returns a human-readable warning per entry
    /// that could not be linked, so callers can surface them without blocking
    /// claude startup.
    @discardableResult
    public static func linkAccountDirsToWorkspace(
        accountDir: URL,
        workspaceDir: URL
    ) -> [String] {
        let fm = FileManager.default
        var warnings: [String] = []

        guard let entries = try? fm.contentsOfDirectory(
            at: accountDir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return ["could not read account dir \(accountDir.path)"]
        }

        let backupBase = accountDir
            .appendingPathComponent("backups")
            .appendingPathComponent("premerge-\(premergeStamp())")

        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") { continue }
            if privateSubdirs.contains(name) { continue }

            let vals = try? entry.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            let isSymlink = vals?.isSymbolicLink ?? false
            let isDir = vals?.isDirectory ?? false
            if !isSymlink && !isDir { continue }   // plain file → leave alone

            let target = workspaceDir.appendingPathComponent(name)
            do {
                if isSymlink {
                    try relinkSymlink(link: entry, target: target, fm: fm)
                } else {
                    try fm.createDirectory(
                        at: target, withIntermediateDirectories: true)
                    try mergeTree(
                        from: entry, into: target,
                        backupRoot: backupBase.appendingPathComponent(name),
                        fm: fm)
                    // Only convert to a symlink once the account dir fully
                    // drained. A non-empty remnant means a merge conflict left
                    // items or a concurrent writer added some — leave it in
                    // place (visible, recoverable) and self-heal on a later run,
                    // rather than recursively deleting a possibly-live dir.
                    let remnant = (try? fm.contentsOfDirectory(atPath: entry.path)) ?? []
                    if remnant.isEmpty {
                        try fm.removeItem(at: entry)
                        try fm.createSymbolicLink(
                            at: entry, withDestinationURL: target)
                    } else {
                        warnings.append(
                            "\(name): left in place — \(remnant.count) item(s) remain after merge")
                    }
                }
            } catch {
                warnings.append("\(name): \(error.localizedDescription)")
            }
        }
        return warnings
    }

    /// Point `link` (an existing symlink) at `target`, creating `target` if
    /// needed. No-op when it already points there.
    private static func relinkSymlink(link: URL, target: URL, fm: FileManager) throws {
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path),
           dest == target.path {
            return
        }
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
    }

    /// Recursively merge `from` into `into` (union, `into` wins). Children only
    /// in `from` move into `into`; when both sides have a real directory the
    /// merge recurses; any other same-path conflict moves the `from` copy under
    /// `backupRoot`, preserving relative structure.
    private static func mergeTree(
        from: URL, into: URL, backupRoot: URL, fm: FileManager
    ) throws {
        let children = try fm.contentsOfDirectory(
            at: from,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [])

        for child in children {
            let name = child.lastPathComponent
            let dest = into.appendingPathComponent(name)
            let childVals = try? child.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            let childIsRealDir =
                (childVals?.isDirectory ?? false)
                && !(childVals?.isSymbolicLink ?? false)

            // lstat-aware: a dangling symlink still occupies `dest`, so treat it
            // as present (fileExists follows symlinks and would miss it).
            let destOccupied = fm.fileExists(atPath: dest.path)
                || (try? fm.destinationOfSymbolicLink(atPath: dest.path)) != nil

            if !destOccupied {
                try fm.moveItem(at: child, to: dest)
            } else if childIsRealDir && isRealDir(dest, fm: fm) {
                try mergeTree(
                    from: child, into: dest,
                    backupRoot: backupRoot.appendingPathComponent(name), fm: fm)
                // Drop the now-drained source subdir so the parent can become
                // empty and be converted to a symlink.
                removeDirIfEmpty(child, fm: fm)
            } else {
                let backup = backupRoot.appendingPathComponent(name)
                try fm.createDirectory(
                    at: backup.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try fm.moveItem(at: child, to: backup)
            }
        }
    }

    /// Remove `url` only when it is an empty directory. Never deletes content —
    /// avoids clobbering files a concurrent process may have written.
    private static func removeDirIfEmpty(_ url: URL, fm: FileManager) {
        if let kids = try? fm.contentsOfDirectory(atPath: url.path), kids.isEmpty {
            try? fm.removeItem(at: url)
        }
    }

    private static func isRealDir(_ url: URL, fm: FileManager) -> Bool {
        let v = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return (v?.isDirectory ?? false) && !(v?.isSymbolicLink ?? false)
    }

    /// Test-only accessor for the private `isRealDir` check.
    static func isRealDirForTest(_ url: URL) -> Bool {
        isRealDir(url, fm: .default)
    }

    /// Filename-safe UTC timestamp for the premerge backup dir.
    private static func premergeStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: Date())
    }

    public enum Error: Swift.Error, LocalizedError {
        case wrongTool(got: Tool)

        public var errorDescription: String? {
            switch self {
            case .wrongTool(let t):
                return "ClaudeAccountDirectory only handles claude accounts, got \(t.rawValue)."
            }
        }
    }

    /// Create (or repair) the account dir so every shareable subdir is a symlink
    /// into the workspace from `account.workspace`. Real dirs / mislinked
    /// symlinks are moved+relinked via `linkAccountDirsToWorkspace`; the standard
    /// base set is additionally ensured for fresh accounts. Idempotent.
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

        try fm.createDirectory(at: acctDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: wsDir, withIntermediateDirectories: true)

        // Move/relink any shareable dir already present in the account dir, and
        // surface any warnings (partial / failed migrations) to stderr rather
        // than silently succeeding.
        let linkWarnings = linkAccountDirsToWorkspace(
            accountDir: acctDir, workspaceDir: wsDir)
        for w in linkWarnings {
            FileHandle.standardError.write(
                Data("orrery: link-workspace: \(w)\n".utf8))
        }

        // Ensure the standard base set exists as symlinks even on a fresh
        // account where claude hasn't created those dirs yet (nothing to move).
        for sub in sharedSubdirs {
            let target = wsDir.appendingPathComponent(sub)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            let link = acctDir.appendingPathComponent(sub)
            if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                if dest != target.path {
                    try fm.removeItem(at: link)
                    try fm.createSymbolicLink(at: link, withDestinationURL: target)
                }
            } else if fm.fileExists(atPath: link.path) {
                if isRealDir(link, fm: fm) {
                    // The linker could not fully migrate this real dir (it emits
                    // a warning above). Leave the data in place and visible —
                    // NEVER hide a real data directory in backups — a later run
                    // retries the merge.
                    continue
                }
                // A stray plain file sits at a base path — back it up, then
                // symlink so the account self-heals instead of staying `.missing`.
                let backup = acctDir
                    .appendingPathComponent("backups")
                    .appendingPathComponent("premerge-\(premergeStamp())")
                    .appendingPathComponent(sub)
                try fm.createDirectory(
                    at: backup.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try fm.moveItem(at: link, to: backup)
                try fm.createSymbolicLink(at: link, withDestinationURL: target)
            } else {
                try fm.createSymbolicLink(at: link, withDestinationURL: target)
            }
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
