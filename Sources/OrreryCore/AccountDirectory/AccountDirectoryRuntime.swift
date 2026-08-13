import Foundation

/// Status of a tool account's symlinks into its pinned workspace.
public enum AccountDirSymlinkStatus: Equatable, Sendable {
    /// All expected symlinks present, pointing at the expected workspace, and
    /// their targets exist on disk.
    case ok
    /// One or more symlinks are missing, OR present but their target doesn't
    /// exist (broken symlink).
    case missing
    /// One or more symlinks point at a different workspace than the account's
    /// current pin.
    case mismatch
    /// This tool doesn't have an account-directory manager registered.
    case notApplicable
}

/// One implementation per `Tool`: how that tool's per-account directory is
/// built and kept in sync with its pinned workspace. Concrete implementations
/// (`ClaudeAdapter`, `CodexAdapter`, …) live in `OrreryAccountKit`, a separate
/// target — Core-resident commands reach them only through
/// `AccountDirectoryRuntime`, never by importing that target directly.
public protocol ToolAccountManaging: Sendable {
    var tool: Tool { get }

    /// The env var name the shell should export for this tool (e.g.
    /// `"CLAUDE_CONFIG_DIR"`, `"CODEX_HOME"`).
    var exportEnvVarName: String { get }

    /// The path to export as `exportEnvVarName`'s value for this account. For
    /// most tools this is just the account dir. Override when the tool can't
    /// take its config dir from an env var directly — gemini-cli ignores
    /// `GEMINI_CONFIG_DIR` and only reads `$HOME/.gemini`, so `GeminiAdapter`
    /// returns a wrapper dir (containing a `.gemini` symlink back to the
    /// account dir) that gets exported as `ORRERY_GEMINI_HOME` instead.
    func resolvedExportPath(accountDir: URL) throws -> URL

    /// Inverse of `resolvedExportPath`: recover the account id from an
    /// exported path (e.g. for `ShowCommand`'s shell-only-override detection,
    /// which reads the env var back and needs to know which account it names).
    func accountID(fromExportPath path: URL) -> String

    /// Build (or repair) the account dir so its shareable subdirs are symlinks
    /// into the pinned workspace. Idempotent.
    func prepareDirectory(
        account: Account,
        accountStore: AccountStore,
        environmentStore: EnvironmentStore
    ) throws

    /// Pure read: do the account's symlinks match its current workspace pin?
    func verifySymlinks(
        account: Account,
        accountStore: AccountStore,
        environmentStore: EnvironmentStore
    ) -> AccountDirSymlinkStatus

    /// Gap-fill only: symlink any shareable workspace dir the account is
    /// missing, without migrating or moving anything. Safe to call on every
    /// launch (claude) or on-demand (codex).
    @discardableResult
    func mirrorWorkspaceDirsToAccount(accountDir: URL, workspaceDir: URL) -> [String]
}

extension ToolAccountManaging {
    public func resolvedExportPath(accountDir: URL) throws -> URL { accountDir }
    public func accountID(fromExportPath path: URL) -> String { path.lastPathComponent }
}

public enum ToolAccountDirectoryError: Error, LocalizedError {
    case notRegistered(Tool)

    public var errorDescription: String? {
        switch self {
        case .notRegistered(let tool):
            return "AccountDirectoryRuntime: no manager registered for \(tool.rawValue)"
        }
    }
}

/// Factory registered by the binary at startup so Core-resident CLI commands
/// can obtain concrete `ToolAccountManaging` implementations that live in
/// `OrreryAccountKit` without Core depending on that target. Mirrors
/// `ThirdPartyRuntime`'s injection shape.
public enum AccountDirectoryRuntime {
    nonisolated(unsafe) public static var makeManager: (@Sendable (Tool) -> ToolAccountManaging?)?

    public static func manager(for tool: Tool) throws -> ToolAccountManaging {
        guard let m = makeManager?(tool) else {
            throw ToolAccountDirectoryError.notRegistered(tool)
        }
        return m
    }

    /// Non-throwing lookup for call sites that already treat "no manager for
    /// this tool" as a legitimate, silent no-op (e.g. gemini before its
    /// adapter ships).
    public static func manager(ifAvailable tool: Tool) -> ToolAccountManaging? {
        makeManager?(tool)
    }
}
