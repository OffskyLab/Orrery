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

        let acctStore = AccountStore.default
        let envStore = EnvironmentStore.default

        guard let acct = try acctStore.findByDisplayName(name, tool: tool) else {
            throw ValidationError("Account '\(name)' not found in the \(tool.rawValue) pool.")
        }

        // Per-account dirs are claude-only for now.
        guard tool == .claude else {
            throw ValidationError("Tool '\(tool.rawValue)' is not in v3.1 layout (per-account dirs are claude-only).")
        }

        let status = ClaudeAccountDirectory.verifySymlinks(
            account: acct, accountStore: acctStore, environmentStore: envStore)
        guard status == .ok else {
            throw ValidationError("Account '\(name)' is not yet in v3.1 layout (status: \(status)). Run `orrery migrate-to-v3.1` first.")
        }

        let dir = acctStore.accountDir(id: acct.id, tool: .claude)
        print(dir.path)
    }
}
