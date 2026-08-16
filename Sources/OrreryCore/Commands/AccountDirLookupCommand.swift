import ArgumentParser
import Foundation

/// Internal subcommand wired into the v3.1 `use)` shell-function case.
///
/// `orrery-bin _account-dir <name> [--claude|--codex|--gemini]`
///
/// Prints the absolute path of the v3.1 per-account dir to stdout if the
/// account exists AND has the v3.1 layout (symlinks in place). Exits non-zero
/// with a clear error otherwise — letting the shell function fall back to
/// the v3.0.4 materialize path.
public struct AccountDirLookupCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_account-dir",
        abstract: "(internal) Print the v3.1 account dir path for an account, or exit non-zero.",
        shouldDisplay: false
    )

    @Argument(help: ArgumentHelp("Account display name."))
    public var name: String

    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagClaudeHelp))
    public var claude: Bool = false
    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagCodexHelp))
    public var codex: Bool = false
    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagGeminiHelp))
    public var gemini: Bool = false

    public init() {}

    public func run() throws {
        let selected: [Tool] = [claude ? Tool.claude : nil,
                                codex ? Tool.codex : nil,
                                gemini ? Tool.gemini : nil].compactMap { $0 }
        guard selected.count <= 1 else {
            throw ValidationError("Pass at most one of --claude, --codex, --gemini.")
        }
        let tool: Tool = selected.first ?? .claude

        let exportPath = try Self.resolveExportPath(name: name, tool: tool)
        print(exportPath.path)
    }

    /// Resolve the absolute v3.1 account-dir export path for `name`/`tool`, or
    /// throw a `ValidationError` with the same diagnostics `run()` prints.
    ///
    /// Shared with `PhantomNextCommand`, which needs this exact resolution
    /// (account exists → v3.1 layout manager registered → symlinks verified
    /// `.ok` → export path) to decide what to `export` before relaunching
    /// claude after a phantom account switch. Do not duplicate this logic —
    /// both callers must agree on what counts as a resolvable account dir.
    static func resolveExportPath(name: String, tool: Tool) throws -> URL {
        let acctStore = AccountStore.default
        let envStore = EnvironmentStore.default

        guard let acct = try acctStore.findByDisplayName(name, tool: tool) else {
            throw ValidationError("Account '\(name)' not found in the \(tool.rawValue) pool.")
        }

        guard let manager = AccountDirectoryRuntime.manager(ifAvailable: tool) else {
            throw ValidationError("Tool '\(tool.rawValue)' is not in v3.1 layout (no account-dir manager registered).")
        }

        let status = manager.verifySymlinks(
            account: acct, accountStore: acctStore, environmentStore: envStore)
        guard status == .ok else {
            throw ValidationError("Account '\(name)' is not yet in v3.1 layout (status: \(status)).")
        }

        let dir = acctStore.accountDir(id: acct.id, tool: tool)
        return try manager.resolvedExportPath(accountDir: dir)
    }
}
