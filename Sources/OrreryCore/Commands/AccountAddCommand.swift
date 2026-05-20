import ArgumentParser
import Foundation

public struct AccountAddCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: L10n.Account.addAbstract
    )

    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagClaudeHelp)) public var claude: Bool = false
    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagCodexHelp)) public var codex: Bool = false
    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagGeminiHelp)) public var gemini: Bool = false

    @Option(name: .long, help: ArgumentHelp(L10n.Account.addNameHelp))
    public var name: String?

    /// 測試用隱藏旗標：略過實際登入流程，只把 account 寫進 store。
    @Flag(name: .customLong("skip-login"), help: ArgumentHelp(visibility: .hidden))
    public var skipLogin: Bool = false

    public init() {}

    public func run() throws {
        let tool = try AccountAddCommand.resolveTool(claude: claude, codex: codex, gemini: gemini)
        let displayName = try resolveName()

        if try AccountStore.default.findByDisplayName(displayName, tool: tool) != nil {
            throw ValidationError(L10n.Account.addDuplicateName(displayName, tool.rawValue))
        }

        var account = Account(tool: tool, displayName: displayName)
        #if os(macOS)
        if tool == .claude {
            account.keychainItem = ClaudeKeychain.serviceName(forOrreryAccount: account.id)
        }
        #endif

        try AccountStore.default.save(account)

        if !skipLogin {
            try AccountLoginFlow.run(account: account)
        }

        print(L10n.Account.addCreated(tool.rawValue, displayName))
    }

    /// --claude / --codex / --gemini 三選一，預設 .claude。多選則拋錯。
    internal static func resolveTool(claude: Bool, codex: Bool, gemini: Bool) throws -> Tool {
        let count = [claude, codex, gemini].filter { $0 }.count
        if count > 1 {
            throw ValidationError(L10n.Account.addToolsTooMany)
        }
        if codex { return .codex }
        if gemini { return .gemini }
        return .claude
    }

    private func resolveName() throws -> String {
        if let n = name, !n.isEmpty { return n }
        print(L10n.Account.addNamePrompt, terminator: "")
        guard let input = readLine()?.trimmingCharacters(in: .whitespaces),
              !input.isEmpty
        else {
            throw ValidationError(L10n.Account.addEmptyName)
        }
        return input
    }
}
