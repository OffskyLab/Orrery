import ArgumentParser
import Foundation

public struct UseCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "use",
        abstract: L10n.Account.useAbstract
    )

    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagClaudeHelp))
    public var claude: Bool = false
    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagCodexHelp))
    public var codex: Bool = false
    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagGeminiHelp))
    public var gemini: Bool = false

    @Argument(help: ArgumentHelp(L10n.Account.nameSelectorHelp))
    public var name: String

    public init() {}

    public func run() throws {
        let tool = try AddCommand.resolveTool(claude: claude, codex: codex, gemini: gemini)

        // In v3.1, claude account selection is handled entirely by the orrery()
        // shell function (which exports CLAUDE_CONFIG_DIR). The binary has no
        // materialize path for claude, so calling `orrery-bin use --claude` would
        // pin the account in the store but never activate it. Throw early so the
        // user gets a clear diagnostic instead of a silent no-op.
        if tool == .claude {
            throw ValidationError(
                "claude account selection is handled by the orrery() shell function. " +
                "Source ~/.orrery/activate.sh and run `orrery use --claude <name>` " +
                "instead of `orrery-bin use --claude <name>`."
            )
        }

        let acctStore = AccountStore.default
        guard let acct = try acctStore.findByDisplayName(name, tool: tool) else {
            throw ValidationError(L10n.Account.useNotFound(name, tool.rawValue))
        }

        let envStore = EnvironmentStore.default
        let activeEnv = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]

        // Sync-back the CURRENTLY-pinned account BEFORE repinning, so whatever the
        // tool last wrote (e.g. a token it refreshed) is captured into the old
        // account's pool entry. Best-effort — a sync-back failure must not abort
        // the switch.
        do {
            try RunCommand.prepareSyncBack(tool: tool, envName: activeEnv)
        } catch {
            FileHandle.standardError.write(Data(
                "orrery: warning: could not sync back the previous \(tool.rawValue) account: \(error)\n".utf8))
        }

        // Repin to the new account.
        let targetEnvName: String
        if let activeEnv, activeEnv != Workspace.reservedOriginName {
            var env = try envStore.load(named: activeEnv)
            env.setAccount(acct.id, for: tool)
            try envStore.save(env)
            targetEnvName = activeEnv
        } else {
            var origin = envStore.loadOriginWorkspace()
            origin.setAccount(acct.id, for: tool)
            try envStore.saveOriginWorkspace(origin)
            targetEnvName = Workspace.reservedOriginName
        }

        // Materialize the newly-pinned account into the live slot the tool reads,
        // so a plain `codex`/`gemini` invocation picks up the switch without
        // needing `orrery run`. Best-effort — the pin change already succeeded and
        // materialize is retryable; warn so the user knows they may need to log in.
        do {
            try RunCommand.prepareMaterialize(tool: tool, envName: targetEnvName)
        } catch {
            FileHandle.standardError.write(Data(
                "orrery: warning: could not materialize \(tool.rawValue) credentials for '\(name)': \(error)\n".utf8))
        }

        print(L10n.Account.usePinned(tool.rawValue, name, targetEnvName))
    }
}
