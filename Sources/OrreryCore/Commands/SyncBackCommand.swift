import ArgumentParser
import Foundation

/// `orrery-bin _syncback <tool>` — invoked by the phantom supervisor loop in the
/// generated shell function, immediately after `claude` exits and BEFORE the
/// sentinel changes which account/env is active.
///
/// Sync-back is the reverse of `_materialize`. macOS Claude's pool entry is a
/// COPY of the credential (a Keychain item can't be symlinked), and Claude
/// rotates its OAuth token on every refresh — writing the new token to the live
/// Keychain slot, never to the pool. Without sync-back the pool snapshot goes
/// stale and switching back to that account 401s. This command copies the
/// just-used tool's live credential back into the pinned account's pool entry.
/// For symlink-based tools (codex/gemini/Linux-claude) it is a genuine no-op.
///
/// A sync-back failure is non-fatal: it warns to stderr and exits 0 so the
/// supervisor loop is never broken by it.
public struct SyncBackCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_syncback",
        abstract: "Sync a tool's refreshed credentials back into the accounts pool.",
        shouldDisplay: false
    )

    @Argument(help: "The tool to sync credentials back for (claude/codex/gemini).")
    public var tool: String

    public init() {}

    public func run() throws {
        guard let resolvedTool = Tool(rawValue: tool) else {
            // Unknown tool — nothing to sync back. Not an error.
            return
        }
        let envName = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
        do {
            try RunCommand.prepareSyncBack(tool: resolvedTool, envName: envName)
        } catch {
            FileHandle.standardError.write(Data(
                "orrery: warning: could not sync back \(tool) credentials: \(error)\n".utf8
            ))
        }
    }
}
