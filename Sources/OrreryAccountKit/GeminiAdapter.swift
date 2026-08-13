import Foundation
import OrreryCore

/// Gemini's `ToolAccountManaging` implementation.
///
/// gemini-cli ignores `GEMINI_CONFIG_DIR` entirely — it only ever reads
/// `$HOME/.gemini`. The pre-v3.1 code already worked around this
/// (`EnvironmentStore.ensureGeminiHomeWrapper`): a *sibling* wrapper
/// directory containing a relative `.gemini -> ../<name>` symlink, exported
/// as `ORRERY_GEMINI_HOME` for the shell's `gemini()` wrapper function to set
/// `HOME` to before invoking the real binary. `resolvedExportPath` reproduces
/// that exact shape at the account-dir level: `accounts/gemini/<id>-home/`
/// with `.gemini -> ../<id>`.
///
/// Allowlist is deliberately just `tmp` (gemini's session-checkpoint dir,
/// `tmp/<project-hash>/chats/*` — confirmed against real usage, matching
/// `Tool.sessionSubdirectories`). gemini-cli also has its own `skills`/
/// `extensions` subsystems, but neither directory has been observed with
/// real content yet — add them once their on-disk names are confirmed by
/// actual use rather than guessing.
public struct GeminiAdapter: ToolAccountManaging {
    public let tool: Tool = .gemini
    public let exportEnvVarName = "ORRERY_GEMINI_HOME"

    public static let baseSharedSubdirs: [String] = ["tmp"]

    public static let policy = AccountDirSharingPolicy.allowlist(Set(baseSharedSubdirs))

    public init() {}

    public enum Error: Swift.Error, LocalizedError {
        case wrongTool(got: Tool)

        public var errorDescription: String? {
            switch self {
            case .wrongTool(let t):
                return "GeminiAdapter only handles gemini accounts, got \(t.rawValue)."
            }
        }
    }

    public func prepareDirectory(
        account: Account,
        accountStore: AccountStore,
        environmentStore: EnvironmentStore
    ) throws {
        guard account.tool == .gemini else {
            throw Error.wrongTool(got: account.tool)
        }

        let fm = FileManager.default
        let acctDir = accountStore.accountDir(id: account.id, tool: .gemini)
        let wsDir = environmentStore.toolConfigDir(tool: .gemini, environment: account.workspace)

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
        guard account.tool == .gemini else { return .notApplicable }

        let fm = FileManager.default
        let acctDir = accountStore.accountDir(id: account.id, tool: .gemini)
        let expectedTargetBase = environmentStore.toolConfigDir(tool: .gemini, environment: account.workspace)

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

    // MARK: - HOME-wrapper export

    /// `accounts/gemini-home/<id>/` — deliberately *outside* `accounts/gemini/`
    /// (a sibling of the `gemini` tool dir, not of the account dir itself).
    /// `AccountStore.list(tool:)` enumerates every entry under `accounts/gemini/`
    /// and tries to load each as an account — a wrapper dir living inside that
    /// directory gets mistaken for a broken pool entry ("skipping unreadable
    /// account '<id>-home'"). Keeping the account id unchanged (just relocated)
    /// also means `accountID(fromExportPath:)` needs no override — the default
    /// `path.lastPathComponent` already recovers it correctly.
    private func wrapperDir(accountDir: URL) -> URL {
        let id = accountDir.lastPathComponent
        let accountsRoot = accountDir.deletingLastPathComponent().deletingLastPathComponent()
        return accountsRoot.appendingPathComponent("gemini-home").appendingPathComponent(id)
    }

    public func resolvedExportPath(accountDir: URL) throws -> URL {
        let fm = FileManager.default
        let wrapper = wrapperDir(accountDir: accountDir)
        try fm.createDirectory(at: wrapper, withIntermediateDirectories: true)

        let link = wrapper.appendingPathComponent(".gemini")
        // wrapper = accounts/gemini-home/<id>/, target = accounts/gemini/<id>/:
        // up to gemini-home/, up to accounts/, down into gemini/<id>.
        let relativeTarget = "../../gemini/\(accountDir.lastPathComponent)"
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            if dest == relativeTarget || dest == accountDir.path {
                return wrapper
            }
            try fm.removeItem(at: link)
        } else if fm.fileExists(atPath: link.path) {
            try fm.removeItem(at: link)
        }
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: relativeTarget)
        return wrapper
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
