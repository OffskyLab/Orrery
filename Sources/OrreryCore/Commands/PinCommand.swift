import ArgumentParser
import Foundation

public struct PinCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "pin",
        abstract: L10n.Pin.abstract
    )

    @Argument(help: ArgumentHelp(L10n.Pin.argAccountHelp))
    public var accountName: String = ""

    @Option(name: .long, help: ArgumentHelp(L10n.Pin.flagWorkspaceHelp))
    public var workspace: String = "origin"

    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagClaudeHelp))
    public var claude: Bool = false
    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagCodexHelp))
    public var codex: Bool = false
    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagGeminiHelp))
    public var gemini: Bool = false

    public init() {}

    public func run() throws {
        let tool = resolvedTool()
        let acctStore = AccountStore.default
        let envStore = EnvironmentStore.default

        guard var acct = try acctStore.findByDisplayName(accountName, tool: tool) else {
            throw ValidationError(L10n.Pin.errorAccountNotFound(accountName, tool.rawValue))
        }

        acct.workspace = workspace
        try acctStore.save(acct)

        if tool == .claude {
            try ClaudeAccountDirectory.prepareDirectory(
                account: acct,
                accountStore: acctStore,
                environmentStore: envStore
            )
        }

        print(L10n.Pin.success(accountName, workspace))
    }

    /// Pick the tool from flags. Default: claude.
    private func resolvedTool() -> Tool {
        if codex { return .codex }
        if gemini { return .gemini }
        return .claude
    }
}
