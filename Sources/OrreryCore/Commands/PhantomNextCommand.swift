import ArgumentParser
import Foundation

/// `orrery-bin _phantom-next --id <id>`
///
/// Called by the `claude()` supervisor loop each time claude exits. Exits
/// non-zero when there is no sentinel, which the shell reads as "claude
/// exited normally, leave the loop". Otherwise it prints a small shell script
/// for the caller to `eval` — up to an `export <VAR>=<dir>` line to switch
/// which account's credentials the next claude launch reads, followed by a
/// `set --` line carrying the resume argv.
///
/// The account switch can ONLY happen this way, not by mutating the account
/// store from this process: for claude, switching accounts means exporting
/// `CLAUDE_CONFIG_DIR` in the *supervisor's own shell* — a child process can
/// never do that to its parent. This is why `UseCommand` refuses `--claude`
/// (`Sources/OrreryCore/Commands/UseCommand.swift`): its shell counterpart
/// (`ShellFunctionGenerator`'s `use)` case) never calls into the binary for
/// claude either, it resolves the export path itself and exports directly.
/// `_phantom-next` follows the same shape `_phantom-begin` already
/// established — print shell source, let the caller `eval` it.
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

        guard let script = try Self.advance(
            id: id,
            registry: registry,
            resolveAccountDir: { toolRawValue, name in
                guard let tool = Tool(rawValue: toolRawValue) else { return nil }
                return try? AccountDirLookupCommand.resolveExportPath(name: name, tool: tool).path
            },
            resolveSessionId: { PhantomSupport.findCurrentClaudeSessionId() }
        ) else {
            throw ExitCode.failure
        }
        print(script)
    }

    // MARK: - Testable core

    /// Returns the next iteration's eval-able script, or nil when the loop
    /// should end.
    ///
    /// `resolveAccountDir` and `resolveSessionId` are injected so the whole
    /// decision path is testable without mutating real account state or
    /// needing a live claude session on disk.
    ///
    /// `resolveAccountDir` returning nil (account missing, or not in v3.1
    /// layout) is not fatal: the switch is dropped — no `export` line — but
    /// the loop still relaunches and resumes the conversation on the
    /// unchanged account. Losing the switch is acceptable; losing the
    /// session is not.
    static func advance(
        id: String,
        registry: PhantomRegistry,
        resolveAccountDir: (String, String) -> String?,
        resolveSessionId: () -> String?
    ) throws -> String? {
        let sentinelURL = registry.sentinelURL(id: id)
        guard let sentinel = PhantomSupport.readSentinel(at: sentinelURL) else {
            return nil
        }
        // Consume it first: a sentinel that survives a failure here would
        // re-fire on every subsequent iteration.
        try? FileManager.default.removeItem(at: sentinelURL)

        var lines: [String] = []
        if let tool = sentinel.tool, let name = sentinel.name {
            if let dirPath = resolveAccountDir(tool, name), let varName = Self.exportVarName(forTool: tool) {
                lines.append(Self.exportLine(varName: varName, dirPath: dirPath))
            } else {
                let warning = "orrery: phantom: could not resolve the account dir for "
                    + "\(tool) '\(name)'; continuing on the current account\n"
                FileHandle.standardError.write(Data(warning.utf8))
            }
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

        lines.append(Self.resumeSetLine(sessionId: sessionId))
        return lines.joined(separator: "\n")
    }

    /// The shell variable a tool's account switch is activated through.
    /// NOT `Tool.envVarName` for gemini: gemini-cli ignores
    /// `GEMINI_CONFIG_DIR`, so the shell's `use)` case (and this one, to
    /// match) exports `ORRERY_GEMINI_HOME` instead — see `gemini()` in
    /// `ShellFunctionGenerator`. Unknown tool names return nil so a corrupt
    /// or future-version sentinel is dropped rather than exporting garbage.
    static func exportVarName(forTool tool: String) -> String? {
        switch tool {
        case "claude": return "CLAUDE_CONFIG_DIR"
        case "codex": return "CODEX_HOME"
        case "gemini": return "ORRERY_GEMINI_HOME"
        default: return nil
        }
    }

    static func exportLine(varName: String, dirPath: String) -> String {
        "export \(varName)=\(ShellQuote.single(dirPath))"
    }

    /// The user's original flags are deliberately dropped — they may include a
    /// now-stale `--resume`.
    static func resumeSetLine(sessionId: String?) -> String {
        guard let sessionId, !sessionId.isEmpty else { return "set --" }
        return "set -- --resume \(ShellQuote.single(sessionId))"
    }
}
