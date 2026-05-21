import ArgumentParser
import Foundation

public struct AccountUseCommand: ParsableCommand {
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

    @Option(name: .long, help: ArgumentHelp(L10n.Account.nameSelectorHelp))
    public var name: String

    public init() {}

    public func run() throws {
        let tool = try AccountAddCommand.resolveTool(claude: claude, codex: codex, gemini: gemini)
        let acctStore = AccountStore.default
        guard let acct = try acctStore.findByDisplayName(name, tool: tool) else {
            throw ValidationError(L10n.Account.useNotFound(name, tool.rawValue))
        }

        let envStore = EnvironmentStore.default
        let activeEnv = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]

        // Sync-back the CURRENTLY-pinned account BEFORE repinning, so whatever the
        // tool last wrote (e.g. a token Claude refreshed) is captured into the old
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
        if let activeEnv, activeEnv != ReservedEnvironment.defaultName {
            var env = try envStore.load(named: activeEnv)
            env.setAccount(acct.id, for: tool)
            try envStore.save(env)
            targetEnvName = activeEnv
        } else {
            var origin = envStore.loadOriginConfig()
            origin.setAccount(acct.id, for: tool)
            try envStore.saveOriginConfig(origin)
            targetEnvName = ReservedEnvironment.defaultName
        }

        // Materialize the newly-pinned account into the live slot the tool reads,
        // so a plain `claude`/`codex`/`gemini` invocation picks up the switch
        // without needing `orrery run`. Best-effort — the pin change already
        // succeeded and materialize is retryable; warn so the user knows they may
        // need to log in.
        do {
            try RunCommand.prepareMaterialize(tool: tool, envName: activeEnv)
        } catch {
            FileHandle.standardError.write(Data(
                "orrery: warning: could not place credentials for '\(name)': \(error)\n".utf8))
        }

        print(L10n.Account.usePinned(tool.rawValue, name, targetEnvName))
    }
}
