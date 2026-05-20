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

        print(L10n.Account.usePinned(tool.rawValue, name, targetEnvName))
    }
}
