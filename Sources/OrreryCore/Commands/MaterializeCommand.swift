import ArgumentParser
import Foundation

/// `orrery-bin _materialize <tool>` — invoked by the phantom supervisor loop in
/// the generated shell function, immediately before it forks `claude`.
///
/// The phantom path launches `claude` directly from the shell (so the loop can
/// supervise relaunches), bypassing `orrery-bin run` / `RunCommand.run()`. This
/// command is therefore the only place the pinned account's credentials get
/// materialized for `orrery run claude` — without it, `orrery account use` and
/// `/orrery:phantom account` would update the pin but never take effect.
///
/// A materialize failure is non-fatal: it warns to stderr and exits 0 so the
/// supervisor loop still launches the tool (which surfaces its own login state).
public struct MaterializeCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_materialize",
        abstract: "Materialize the active env's pinned account credentials for a tool.",
        shouldDisplay: false
    )

    @Argument(help: "The tool to materialize credentials for (claude/codex/gemini).")
    public var tool: String

    public init() {}

    public func run() throws {
        guard let resolvedTool = Tool(rawValue: tool) else {
            // Unknown tool — nothing to materialize. Not an error.
            return
        }
        let envName = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
        do {
            try RunCommand.prepareMaterialize(tool: resolvedTool, envName: envName)
        } catch {
            FileHandle.standardError.write(Data(
                "orrery: warning: could not materialize \(tool) credentials: \(error)\n".utf8
            ))
        }
    }
}
