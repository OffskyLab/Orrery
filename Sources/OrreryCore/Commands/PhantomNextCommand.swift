import ArgumentParser
import Foundation

/// `orrery-bin _phantom-next --id <id>`
///
/// Called by the `claude()` supervisor loop each time claude exits. Exits
/// non-zero when there is no sentinel, which the shell reads as "claude
/// exited normally, leave the loop". Otherwise it applies the pending account
/// switch and prints the argv for the next iteration.
///
/// The pin is applied here rather than at trigger time on purpose: `orrery
/// use` syncs the just-used account's refreshed credential back into the pool
/// before repinning, so flipping the pin while the old claude was still alive
/// would copy its live token into the new account's pool entry.
public struct PhantomNextCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_phantom-next",
        shouldDisplay: false
    )

    @Option(name: .long) public var id: String

    public init() {}

    public func run() throws {
        let store = EnvironmentStore.default
        let registry = PhantomRegistry(homeURL: store.homeURL)

        guard let argv = try Self.advance(
            id: id,
            registry: registry,
            applyPin: { tool, name in
                try? Self.runUse(tool: tool, name: name)
            },
            resolveSessionId: { PhantomSupport.findCurrentClaudeSessionId() }
        ) else {
            throw ExitCode.failure
        }
        print(argv)
    }

    // MARK: - Testable core

    /// Returns the next iteration's argv, or nil when the loop should end.
    ///
    /// `applyPin` and `resolveSessionId` are injected so the whole decision
    /// path is testable without mutating real account state or needing a live
    /// claude session on disk.
    static func advance(
        id: String,
        registry: PhantomRegistry,
        applyPin: (String, String) -> Void,
        resolveSessionId: () -> String?
    ) throws -> String? {
        let sentinelURL = registry.sentinelURL(id: id)
        guard let sentinel = PhantomSupport.readSentinel(at: sentinelURL) else {
            return nil
        }
        // Consume it first: a sentinel that survives a failure here would
        // re-fire on every subsequent iteration.
        try? FileManager.default.removeItem(at: sentinelURL)

        if let tool = sentinel.tool, let name = sentinel.name {
            applyPin(tool, name)
        }

        var entry = registry.read(id: id)

        // A hook-reported session id is authoritative; only fall back to
        // probing (newest session file by mtime) when we have none.
        let sessionId: String?
        if let entry, entry.sessionIdSource == .hook, let known = entry.sessionId {
            sessionId = known
        } else {
            sessionId = sentinel.sessionId ?? resolveSessionId()
        }

        if var e = entry {
            if let name = sentinel.name { e.account = name }
            e.sessionId = sessionId
            e.updatedAt = Date().timeIntervalSince1970
            try? registry.write(e, id: id)
            entry = e
        }

        return Self.nextArgv(sessionId: sessionId)
    }

    /// The user's original flags are deliberately dropped — they may include a
    /// now-stale `--resume`.
    static func nextArgv(sessionId: String?) -> String {
        guard let sessionId, !sessionId.isEmpty else { return "" }
        return "--resume \(ShellQuote.single(sessionId))"
    }

    private static func runUse(tool: String, name: String) throws {
        var use = UseCommand()
        use.claude = (tool == "claude")
        use.codex = (tool == "codex")
        use.gemini = (tool == "gemini")
        use.name = name
        try use.run()
    }
}
