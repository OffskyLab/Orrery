import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// `orrery-bin _phantom-begin --tool claude --supervisor-pid $$ -- <args...>`
///
/// Called by the `claude()` shell function before its supervisor loop starts.
/// Registers the supervisor and prints shell `export` lines for the caller to
/// `eval`. Exits non-zero when this invocation should not be supervised, which
/// the shell treats as "just launch normally" — a failure here must never stop
/// the user launching claude.
///
/// `--supervisor-pid` is required rather than inferred: this runs inside a
/// `$(...)` command substitution, which forks a subshell, so `getppid()` would
/// see that transient subshell rather than the interactive shell that owns the
/// loop. `$$` in bash and zsh stays the original shell's pid inside a subshell,
/// so the shell passes it explicitly.
public struct PhantomBeginCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_phantom-begin",
        shouldDisplay: false
    )

    @Option(name: .long) public var tool: String = "claude"
    @Option(name: .long) public var supervisorPid: Int32

    @Argument(parsing: .allUnrecognized) public var args: [String] = []

    public init() {}

    public func run() throws {
        let store = EnvironmentStore.default

        // Judge interactivity from stderr, not stdout: the claude() shim
        // invokes this command inside `$( )`, which replaces fd 1 with a
        // pipe — isatty(1) would then be false on every real terminal
        // launch, vetoing every supervised session unconditionally. Stderr
        // is left attached to the controlling terminal by that same command
        // substitution, so it is the only fd here that still reflects
        // reality. Accepted trade: `claude 2>/dev/null` will not be
        // supervised — the fail-safe direction.
        guard PhantomLaunchPolicy.shouldSupervise(
            args: args,
            stdinIsTTY: isatty(0) == 1,
            outputIsTTY: isatty(2) == 1
        ) else {
            throw ExitCode.failure
        }

        guard let startedAt = ProcessLiveness.startTime(pid: supervisorPid) else {
            throw ExitCode.failure
        }

        Self.removeLegacySentinel(homeURL: store.homeURL)

        let registry = PhantomRegistry(homeURL: store.homeURL)
        let envName = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
        let account = Self.pinnedAccountDisplayName(tool: tool, envName: envName)

        do {
            try Self.begin(
                tool: tool,
                supervisorPid: supervisorPid,
                supervisorStartedAt: startedAt,
                cwd: FileManager.default.currentDirectoryPath,
                tty: Self.currentTTY(),
                workspace: envName,
                account: account,
                registry: registry)
        } catch {
            // Registry unavailable — degrade to an unsupervised launch rather
            // than blocking the user.
            throw ExitCode.failure
        }

        let id = String(supervisorPid)
        print(Self.exportScript(id: id, dirURL: registry.entryDirURL(id: id)))
    }

    /// The display name of whichever account is pinned for `tool` in the
    /// current workspace, or nil when `tool` isn't a recognized `Tool`, no
    /// account is pinned, or the lookup throws — none of which should block
    /// registering the supervisor.
    static func pinnedAccountDisplayName(tool: String, envName: String?) -> String? {
        guard let toolEnum = Tool(rawValue: tool) else { return nil }
        do {
            return try RunCommand.resolvePinnedAccount(tool: toolEnum, envName: envName)?
                .account.displayName
        } catch {
            return nil
        }
    }

    // MARK: - Testable pieces

    static func begin(
        tool: String,
        supervisorPid: Int32,
        supervisorStartedAt: Double,
        cwd: String,
        tty: String?,
        workspace: String?,
        account: String?,
        registry: PhantomRegistry
    ) throws {
        let entry = PhantomEntry(
            supervisorPid: supervisorPid,
            supervisorStartedAt: supervisorStartedAt,
            tool: tool,
            tty: tty,
            cwd: cwd,
            workspace: workspace,
            account: account,
            sessionId: nil,
            sessionIdSource: .probe,
            updatedAt: Date().timeIntervalSince1970)
        try registry.write(entry, id: String(supervisorPid))
    }

    static func exportScript(id: String, dirURL: URL) -> String {
        """
        export ORRERY_PHANTOM_ID=\(ShellQuote.single(id))
        export ORRERY_PHANTOM_DIR=\(ShellQuote.single(dirURL.path))
        """
    }

    /// Pre-registry builds used one shared `<home>/.phantom-sentinel`. Drop it
    /// on the first supervised launch so a leftover never fires unexpectedly.
    static func removeLegacySentinel(homeURL: URL) {
        try? FileManager.default.removeItem(
            at: homeURL.appendingPathComponent(".phantom-sentinel"))
    }

    static func currentTTY() -> String? {
        guard isatty(0) == 1, let name = ttyname(0) else { return nil }
        return String(cString: name)
    }
}
