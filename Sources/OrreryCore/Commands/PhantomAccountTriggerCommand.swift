import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// `orrery phantom [--codex|--gemini] <account> [--session <id|index>]` —
/// invoked to switch which account a tool uses without losing the
/// conversation. Public and model-independent on purpose: the slash command
/// requires a Claude turn to parse `$ARGUMENTS` and invoke this, which isn't
/// available once the account's usage is exhausted — running this directly
/// works regardless, since it's plain process-tree signalling with no LLM
/// involved.
///
/// Session addressing goes through `PhantomRegistry`/`PhantomTargetSelector`
/// rather than an inherited env var, so this also works from another
/// terminal — not just from inside the supervised claude — and disambiguates
/// when several supervised sessions are running concurrently.
///
/// This command does NOT mutate the account pin. It writes a sentinel carrying
/// the target tool+account into that session's registry entry, then signals
/// claude to exit. `_phantom-next` (run by the supervisor loop after claude
/// exits) reads the sentinel and emits shell `export` lines for the loop to
/// `eval` — it never calls `account use` itself. If we flipped the pin here
/// instead, `account use`'s sync-back of the old account's refreshed
/// credential would run against the NEW pin and corrupt the wrong pool entry;
/// deferring the pin change until after the old claude has fully exited is
/// what keeps that sync-back correct.
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

    @Option(name: .long, help: ArgumentHelp(L10n.Phantom.sessionSelectorHelp))
    public var session: String?

    public init() {}

    public func run() throws {
        let tool = try AddCommand.resolveTool(claude: claude, codex: codex, gemini: gemini)
        let store = EnvironmentStore.default
        let registry = PhantomRegistry(homeURL: store.homeURL)

        // Resolve the account first — a typo must never tear down a session.
        guard try AccountStore.default.findByDisplayName(name, tool: tool) != nil else {
            throw ValidationError(L10n.Account.useNotFound(name, tool.rawValue))
        }

        let env = ProcessInfo.processInfo.environment
        let live = registry.liveEntries(isAlive: ProcessLiveness.isAlive)

        // Back-compat: an old shell integration still in the user's rc file
        // sets ORRERY_PHANTOM_SHELL_PID but never registers a registry entry.
        // Fall back to the legacy global sentinel so switching still works,
        // and tell them how to get the new behaviour. Remove in a future
        // release once the registry-based integration has had time to spread.
        if live.isEmpty, let legacyPid = env["ORRERY_PHANTOM_SHELL_PID"],
           let supervisorPid = Int32(legacyPid) {
            try Self.switchLegacy(
                supervisorPid: supervisorPid, tool: tool, name: name, store: store)
            return
        }

        let selection = PhantomTargetSelector.select(
            entries: live,
            envPhantomId: env["ORRERY_PHANTOM_ID"],
            cwd: FileManager.default.currentDirectoryPath,
            explicit: session)

        switch selection {
        case .none:
            throw ValidationError(L10n.Phantom.notUnderPhantom)

        case .ambiguous(let candidates):
            var lines = [L10n.Phantom.ambiguousHeader]
            for (i, c) in candidates.enumerated() {
                lines.append("  \(i + 1)) \(c.entry.tool)  \(c.entry.account ?? "-")"
                    + "  \(c.entry.cwd)  \(c.entry.sessionId?.prefix(8) ?? "-")")
            }
            lines.append(L10n.Phantom.ambiguousHint)
            throw ValidationError(lines.joined(separator: "\n"))

        case .selected(let id, let entry):
            guard let claudePid = Self.findTarget(entry: entry, env: env) else {
                throw ValidationError(L10n.Phantom.claudeNotFound)
            }
            let sessionId = entry.sessionIdSource == .hook
                ? entry.sessionId
                : (entry.sessionId ?? PhantomSupport.findCurrentClaudeSessionId())
            try PhantomSupport.writeSentinel(
                targetAccountTool: tool.rawValue,
                targetAccountName: name,
                sessionId: sessionId,
                to: registry.sentinelURL(id: id))

            if let sid = entry.sessionId {
                print(L10n.Phantom.switchingAccount(name, String(sid.prefix(8))))
            } else {
                print(L10n.Phantom.switchingAccountNoSession(name))
            }

            if kill(claudePid, SIGTERM) != 0 {
                try? FileManager.default.removeItem(at: registry.sentinelURL(id: id))
                throw ValidationError(L10n.Phantom.signalFailed)
            }
        }
    }

    /// In-chain callers walk up from themselves (short, no search); everyone
    /// else descends from the registered supervisor.
    private static func findTarget(entry: PhantomEntry, env: [String: String]) -> Int32? {
        if env["ORRERY_PHANTOM_ID"] == String(entry.supervisorPid) {
            if let pid = PhantomSupport.findClaudeAncestor(
                supervisorPid: entry.supervisorPid) {
                return pid
            }
        }
        return PhantomSupport.resolveClaudePidDownward(
            supervisorPid: entry.supervisorPid,
            children: { PhantomSupport.childPids(of: $0) },
            lookup: { PhantomSupport.readProcessInfo(pid: $0) })
    }

    private static func switchLegacy(
        supervisorPid: Int32, tool: Tool, name: String, store: EnvironmentStore
    ) throws {
        guard let claudePid = PhantomSupport.findClaudeAncestor(
            supervisorPid: supervisorPid) else {
            throw ValidationError(L10n.Phantom.claudeNotFound)
        }
        let legacyURL = store.homeURL.appendingPathComponent(".phantom-sentinel")
        try PhantomSupport.writeSentinel(
            targetAccountTool: tool.rawValue, targetAccountName: name,
            sessionId: PhantomSupport.findCurrentClaudeSessionId(), to: legacyURL)
        FileHandle.standardError.write(Data((L10n.Phantom.legacySupervisor + "\n").utf8))
        if kill(claudePid, SIGTERM) != 0 {
            try? FileManager.default.removeItem(at: legacyURL)
            throw ValidationError(L10n.Phantom.signalFailed)
        }
    }
}
