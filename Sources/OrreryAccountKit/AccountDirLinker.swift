import Foundation

/// Which top-level names in a tool's config dir are shared into the pinned
/// workspace vs. kept private to the account. Dotfiles are always private
/// under either policy, and only directories/symlinks are ever migrated —
/// a plain file is left exactly where it is, regardless of its name.
public enum AccountDirSharingPolicy: Sendable {
    /// Share everything except these names. Matches claude's original v3.1
    /// design: most of a tool's directory is assumed safe to share, a short
    /// list of exceptions stays private.
    case blocklist(Set<String>)
    /// Share only these names. Safer default for a directory that's mostly
    /// runtime noise (sqlite/log/cache) rather than config — "if unsure,
    /// keep it private."
    case allowlist(Set<String>)

    public func isShareable(_ name: String) -> Bool {
        guard !name.hasPrefix(".") else { return false }
        switch self {
        case .blocklist(let blocked): return !blocked.contains(name)
        case .allowlist(let allowed): return allowed.contains(name)
        }
    }
}

/// Generic account-dir ⟷ workspace-dir symlink engine, extracted from
/// claude's original v3.1 implementation so codex (and later gemini) can
/// reuse the exact same move/merge/symlink mechanics under a different
/// `AccountDirSharingPolicy`.
public enum AccountDirLinker {

    /// Move every shareable top-level directory in `accountDir` into
    /// `workspaceDir` and replace it with a symlink pointing there. Shareable =
    /// a directory (or existing symlink) whose name passes `policy` and isn't
    /// dot-prefixed. Top-level plain files are never touched.
    ///
    /// Merge is a union with the workspace winning: files present only in the
    /// account move over; on a same-path conflict the workspace copy is kept and
    /// the account copy is moved to `<accountDir>/backups/premerge-<timestamp>/`.
    ///
    /// Best-effort: never throws. Returns a human-readable warning per entry
    /// that could not be linked, so callers can surface them without blocking
    /// tool startup.
    @discardableResult
    public static func linkAccountDirsToWorkspace(
        accountDir: URL,
        workspaceDir: URL,
        policy: AccountDirSharingPolicy
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
            guard policy.isShareable(name) else { continue }

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

        // Second pass — mirror the workspace back into the account.
        warnings.append(contentsOf: mirrorWorkspaceDirsToAccount(
            accountDir: accountDir, workspaceDir: workspaceDir, policy: policy))

        return warnings
    }

    /// Ensure every shareable directory in `workspaceDir` has a symlink in
    /// `accountDir` (workspace→account). A dir another account created in the
    /// shared workspace (or one added directly) has no counterpart here, so this
    /// fills that gap.
    ///
    /// Never moves or merges account data. Gap-fill only — names the account
    /// already has (a real dir, a plain file, or an existing symlink) are left
    /// untouched. Skips dotfiles, names `policy` doesn't allow, and non-directory
    /// workspace entries. Best-effort; returns per-entry warnings.
    @discardableResult
    public static func mirrorWorkspaceDirsToAccount(
        accountDir: URL,
        workspaceDir: URL,
        policy: AccountDirSharingPolicy
    ) -> [String] {
        let fm = FileManager.default
        var warnings: [String] = []
        guard let wsEntries = try? fm.contentsOfDirectory(
            at: workspaceDir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return warnings
        }
        for entry in wsEntries {
            let name = entry.lastPathComponent
            guard policy.isShareable(name) else { continue }

            let vals = try? entry.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isRealDir = (vals?.isDirectory ?? false)
                && !(vals?.isSymbolicLink ?? false)
            if !isRealDir { continue }   // only mirror directories

            let link = accountDir.appendingPathComponent(name)
            // lstat-aware occupancy check (fileExists follows symlinks and would
            // miss a dangling one).
            let occupied = fm.fileExists(atPath: link.path)
                || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil
            if occupied { continue }

            // Point at workspaceDir/name (the caller's path), matching the symlink
            // targets pass 1 creates — not the resolved enumeration URL (which
            // standardizes /var → /private/var).
            let target = workspaceDir.appendingPathComponent(name)
            do {
                try fm.createSymbolicLink(at: link, withDestinationURL: target)
            } catch {
                warnings.append(
                    "\(name): could not mirror workspace dir into account: \(error.localizedDescription)")
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

    /// Filename-safe UTC timestamp for the premerge backup dir.
    private static func premergeStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: Date())
    }
}
