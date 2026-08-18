import ArgumentParser
import Foundation

/// Internal subcommand wired into the v3.1 `use)` shell-function case.
///
/// `orrery-bin _pin-current <name> [--claude|--codex|--gemini]`
///
/// Persists `<name>` as the globally-current account for the tool, so a
/// brand-new shell can restore it later via `_current-export`. This is the
/// piece the v3.1 fast path (`_account-dir` + shell export) was missing: it
/// only ever affected the invoking shell, never the on-disk pin (see
/// `ShowCommand`'s "this shell only" detection). Deliberately independent of
/// `ORRERY_ACTIVE_ENV` / workspaces — the pin always lives on the origin
/// workspace, matching `orrery current`'s global-not-per-workspace scope.
public struct PinCurrentAccountCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_pin-current",
        abstract: "(internal) Persist the globally-current account for a tool.",
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
        guard let acct = try acctStore.findByDisplayName(name, tool: tool) else {
            throw ValidationError("Account '\(name)' not found in the \(tool.rawValue) pool.")
        }

        let envStore = EnvironmentStore.default
        var origin = envStore.loadOriginWorkspace()
        origin.setAccount(acct.id, for: tool)
        try envStore.saveOriginWorkspace(origin)
    }
}
