import Foundation
import OrreryCore

public enum CopyFileExecutor {
    /// Marker prefix that makes a lock/`to` path resolve against the workspace
    /// claude dir instead of the account claude dir.
    public static let workspaceMarker = "<WORKSPACE_CLAUDE_DIR>/"

    /// Resolve a manifest `to` / lock path to an absolute URL. Paths beginning
    /// with the workspace marker resolve under `workspaceDir`; all others are
    /// relative to the account `claudeDir` (unchanged behaviour).
    public static func resolveInstalledPath(_ path: String,
                                            claudeDir: URL,
                                            workspaceDir: URL) -> URL {
        if path.hasPrefix(workspaceMarker) {
            return workspaceDir.appendingPathComponent(String(path.dropFirst(workspaceMarker.count)))
        }
        return claudeDir.appendingPathComponent(path)
    }

    /// Copies the file and returns its destination path — verbatim from the
    /// manifest, so a `<WORKSPACE_CLAUDE_DIR>/…` marker is preserved in the lock.
    public static func apply(_ step: ThirdPartyStep,
                             sourceDir: URL, claudeDir: URL, workspaceDir: URL) throws -> [String] {
        guard case .copyFile(let from, let to) = step else {
            throw ThirdPartyError.stepFailed(reason: "not a copyFile step")
        }
        let src = sourceDir.appendingPathComponent(from)
        let dst = resolveInstalledPath(to, claudeDir: claudeDir, workspaceDir: workspaceDir)
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: src, to: dst)

        // Migration: when installing into the workspace, remove any stale copy of
        // the same file left at the pre-workspace ACCOUNT location (older installs
        // put e.g. statusline.js in the account dir). Otherwise a dead account
        // copy lingers after the account's settings.json is re-pointed to the
        // workspace path by the patchSettings step. Never touch a real directory.
        if to.hasPrefix(workspaceMarker) {
            let rel = String(to.dropFirst(workspaceMarker.count))
            let stale = claudeDir.appendingPathComponent(rel)
            let isSymlink = (try? fm.destinationOfSymbolicLink(atPath: stale.path)) != nil
            var isDir: ObjCBool = false
            let existsFollowing = fm.fileExists(atPath: stale.path, isDirectory: &isDir)
            if isSymlink || (existsFollowing && !isDir.boolValue) {
                try? fm.removeItem(at: stale)
            }
        }
        return [to]
    }

    public static func rollback(paths: [String], claudeDir: URL, workspaceDir: URL) {
        let fm = FileManager.default
        for p in paths {
            try? fm.removeItem(at: resolveInstalledPath(p, claudeDir: claudeDir, workspaceDir: workspaceDir))
        }
    }
}
