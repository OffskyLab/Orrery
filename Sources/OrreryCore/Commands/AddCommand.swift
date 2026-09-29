import ArgumentParser
import Foundation

public struct AddCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: L10n.Account.addAbstract
    )

    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagClaudeHelp)) public var claude: Bool = false
    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagCodexHelp)) public var codex: Bool = false
    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagGeminiHelp)) public var gemini: Bool = false

    /// Positional, matching `orrery remove <name>` — `add` used to spell this
    /// `--name`, which made the two halves of one workflow read differently.
    @Argument(help: ArgumentHelp(L10n.Account.addNameHelp))
    public var name: String?

    /// 測試用隱藏旗標：略過實際登入流程，只把 account 寫進 store。
    @Flag(name: .customLong("skip-login"), help: ArgumentHelp(visibility: .hidden))
    public var skipLogin: Bool = false

    public init() {}

    public func run() async throws {
        AddCommand.announceDefaultToolIfNoFlag(claude: claude, codex: codex, gemini: gemini)
        let tool = try AddCommand.resolveTool(claude: claude, codex: codex, gemini: gemini)
        let displayName = try resolveName()

        let listing = AccountListing(store: .default)

        // A plugin-owned tool answers for its own duplicates: its pool is the
        // only one that exists, so asking orrery's would be checking a table
        // nothing writes to.
        let existingNames = try await listing.rows(for: tool, liveAccountID: nil)
            .map(\.displayName)
        if existingNames.contains(displayName) {
            throw ValidationError(L10n.Account.addDuplicateName(displayName, tool.rawValue))
        }

        // The host chooses the id either way, so both paths agree on what an
        // account is called even while they disagree on where it lives.
        let newID = UUID().uuidString

        if try await listing.addIfPluginOwned(
            tool: tool, id: newID, displayName: displayName) != nil {
            print(L10n.Account.addCreated(tool.rawValue, displayName))
            // Said out loud rather than skipped quietly. `AccountLoginFlow` works
            // on orrery's own `Account` — staging dirs, a Keychain item name —
            // and none of that exists for an account the plugin owns. Moving
            // credentials across the boundary is its own piece of work, and
            // printing nothing here would leave someone holding an account that
            // looks finished and cannot be used.
            if !skipLogin {
                let note = "orrery: \(tool.rawValue) accounts are owned by its plugin, and "
                    + "logging in through orrery is not wired to it yet — run "
                    + "`\(tool.rawValue)` in this account and log in there.\n"
                FileHandle.standardError.write(Data(note.utf8))
            }
            return
        }

        var account = OrreryCore.Account(id: newID, tool: tool, displayName: displayName)
        #if os(macOS)
        if tool == .claude {
            account.keychainItem = ClaudeKeychain.serviceName(forOrreryAccount: account.id)
        }
        #endif

        try AccountStore.default.save(account)

        if !skipLogin {
            do {
                try AccountLoginFlow.run(account: account)
            } catch {
                try? AccountStore.default.delete(id: account.id, tool: account.tool)
                throw error
            }
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

    /// When `orrery add` runs without a tool flag it defaults to Claude. Print a
    /// one-line notice (to stderr) so that default is explicit rather than a
    /// silent surprise, and tell the user how to target a different tool.
    /// Shared with the internal `_account-add-prepare` command: the Claude
    /// add path is routed through the shell function to that command, so the
    /// notice has to be emitted from both entry points.
    static func announceDefaultToolIfNoFlag(claude: Bool, codex: Bool, gemini: Bool) {
        guard !claude, !codex, !gemini else { return }
        stderrWrite(L10n.Account.addToolDefaultNotice + "\n")
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
