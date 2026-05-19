import ArgumentParser
import Foundation

/// Internal: reconcile each tool's settings.json so the SessionStart hook
/// matches the current env's `shareUserMemory` flag. Called from the shell
/// `use` function after the env vars are exported.
public struct ReconcileUserMemoryHooksCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_reconcile-user-memory-hooks",
        abstract: "Internal: ensure user-memory SessionStart hooks match the active env's shareUserMemory state.",
        shouldDisplay: false
    )

    public init() {}

    public func run() throws {
        let envName = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
            ?? ReservedEnvironment.defaultName
        let store = EnvironmentStore.default

        let share: Bool
        if envName == ReservedEnvironment.defaultName {
            share = store.loadOriginConfig().shareUserMemory
        } else {
            share = (try? store.load(named: envName))?.shareUserMemory ?? true
        }

        if share {
            try? store.ensureUserMemoryHooks(for: envName)
        } else {
            try? store.removeUserMemoryHooks(for: envName)
        }
    }
}
