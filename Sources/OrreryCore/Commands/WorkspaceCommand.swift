import ArgumentParser
import Foundation

/// `orrery workspace …` — v3.1 alias for `orrery sandbox …`.
///
/// Maintains both names during the migration window. Plan 4 will deprecate
/// and eventually remove `orrery sandbox`. Until then, this is a thin
/// passthrough so users can adopt the new vocabulary without breaking scripts.
public struct WorkspaceCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "workspace",
        abstract: L10n.Sandbox.abstract,
        subcommands: SandboxCommand.configuration.subcommands,
        defaultSubcommand: SandboxCommand.configuration.defaultSubcommand
    )

    public init() {}
}
