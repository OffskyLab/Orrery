import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// `orrery-bin _phantom-trigger-account --<tool> --name <account>` — invoked from
/// inside a phantom-supervised claude (via the `/orrery:phantom` slash command) to
/// switch which account a tool uses, without leaving the current env or losing the
/// conversation. Updates the current env's account pin, then writes a sentinel
/// targeting the SAME env so the supervisor relaunches it — the relaunch's
/// materialize step picks up the new credential.
public struct PhantomAccountTriggerCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_phantom-trigger-account",
        abstract: L10n.Phantom.accountTriggerAbstract,
        shouldDisplay: false
    )

    @Flag(name: .long) public var claude: Bool = false
    @Flag(name: .long) public var codex: Bool = false
    @Flag(name: .long) public var gemini: Bool = false

    @Option(name: .long)
    public var name: String

    public init() {}

    public func run() throws {
        // Must be under a phantom supervisor.
        let supervisorPidStr = ProcessInfo.processInfo.environment["ORRERY_PHANTOM_SHELL_PID"]
        guard let supervisorPidStr, let supervisorPid = Int32(supervisorPidStr) else {
            throw ValidationError(L10n.Phantom.notUnderPhantom)
        }

        let tool = try AccountAddCommand.resolveTool(claude: claude, codex: codex, gemini: gemini)
        let store = EnvironmentStore.default

        // Resolve the account to switch to.
        guard let account = try AccountStore.default.findByDisplayName(name, tool: tool) else {
            throw ValidationError(L10n.Account.useNotFound(name, tool.rawValue))
        }

        // Resolve the current env (origin if ORRERY_ACTIVE_ENV unset/origin).
        let activeEnv = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
        let currentEnvName: String
        if let activeEnv, activeEnv != ReservedEnvironment.defaultName {
            currentEnvName = activeEnv
        } else {
            currentEnvName = ReservedEnvironment.defaultName
        }

        // Find claude FIRST — don't leave a stale sentinel if we can't signal it.
        guard let claudePid = PhantomTriggerCommand.findClaudeAncestor(supervisorPid: supervisorPid) else {
            throw ValidationError(L10n.Phantom.claudeNotFound)
        }

        // Update the pin (origin config vs named env).
        if currentEnvName == ReservedEnvironment.defaultName {
            var origin = store.loadOriginConfig()
            origin.setAccount(account.id, for: tool)
            try store.saveOriginConfig(origin)
        } else {
            var env = try store.load(named: currentEnvName)
            env.setAccount(account.id, for: tool)
            try store.save(env)
        }

        // Write a sentinel targeting the SAME env — the relaunch's materialize
        // step will pick up the just-written pin.
        let sessionId = PhantomTriggerCommand.findCurrentClaudeSessionId()
        try PhantomTriggerCommand.writeSentinel(
            targetEnv: currentEnvName, sessionId: sessionId, store: store)

        print(L10n.Account.usePinned(tool.rawValue, name, currentEnvName))

        // SIGTERM claude so the supervisor relaunches it.
        if kill(claudePid, SIGTERM) != 0 {
            try? FileManager.default.removeItem(at: PhantomTriggerCommand.sentinelURL(store: store))
            throw ValidationError(L10n.Phantom.signalFailed)
        }
    }
}
