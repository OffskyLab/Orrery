import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// `orrery phantom [--codex|--gemini] <account>` — invoked from inside a
/// phantom-supervised claude (directly, via `!` command-mode, or via the
/// `/orrery:phantom` slash command) to switch which account a tool uses,
/// without leaving the current env or losing the conversation. Public and
/// model-independent on purpose: the slash command requires a Claude turn to
/// parse `$ARGUMENTS` and invoke this, which isn't available once the
/// account's usage is exhausted — running this directly works regardless,
/// since it's plain process-tree signalling with no LLM involved.
///
/// This command does NOT mutate the account pin. It writes a sentinel carrying
/// the target tool+account, then signals claude to exit. The supervisor loop
/// applies the pin change (`orrery-bin account use`) AFTER claude exits, and
/// `account use` itself syncs the just-used account's refreshed credential back
/// into the pool BEFORE it repins. If we flipped the pin here, that sync-back
/// would read the new pin and copy the old claude's live token into the NEW
/// account's pool entry — corruption.
public struct PhantomAccountTriggerCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "phantom",
        abstract: L10n.Phantom.accountTriggerAbstract
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
        // Must be under a phantom supervisor.
        let supervisorPidStr = ProcessInfo.processInfo.environment["ORRERY_PHANTOM_SHELL_PID"]
        guard let supervisorPidStr, let supervisorPid = Int32(supervisorPidStr) else {
            throw ValidationError(L10n.Phantom.notUnderPhantom)
        }

        let tool = try AddCommand.resolveTool(claude: claude, codex: codex, gemini: gemini)
        let store = EnvironmentStore.default

        // Resolve the account to switch to — fail fast BEFORE signalling claude
        // so a typo never tears down the running session.
        guard try AccountStore.default.findByDisplayName(name, tool: tool) != nil else {
            throw ValidationError(L10n.Account.useNotFound(name, tool.rawValue))
        }

        // Find claude FIRST — don't leave a stale sentinel if we can't signal it.
        guard let claudePid = PhantomSupport.findClaudeAncestor(supervisorPid: supervisorPid) else {
            throw ValidationError(L10n.Phantom.claudeNotFound)
        }

        // Write a sentinel carrying the target account. The pin is NOT mutated
        // here — the supervisor loop applies `orrery-bin account use` AFTER
        // claude exits, and `account use` syncs the old account's refreshed
        // credential back into the pool before it repins. Flipping the pin now
        // would make that sync-back copy the old claude's live token into the
        // NEW account's pool entry.
        let sessionId = PhantomSupport.findCurrentClaudeSessionId()
        try PhantomSupport.writeSentinel(
            targetAccountTool: tool.rawValue,
            targetAccountName: name,
            sessionId: sessionId,
            store: store
        )

        if let sessionId {
            print(L10n.Phantom.switchingAccount(name, String(sessionId.prefix(8))))
        } else {
            print(L10n.Phantom.switchingAccountNoSession(name))
        }

        // SIGTERM claude so the supervisor relaunches it.
        if kill(claudePid, SIGTERM) != 0 {
            // Signal failed (race with claude exiting) — pull the sentinel back
            // so it doesn't fire on the next manual claude launch.
            try? FileManager.default.removeItem(at: PhantomSupport.sentinelURL(store: store))
            throw ValidationError(L10n.Phantom.signalFailed)
        }
    }
}
