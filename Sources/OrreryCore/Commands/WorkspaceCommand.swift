import ArgumentParser
import Foundation

/// `orrery workspace …` — v3.1 alias for `orrery sandbox …`.
///
/// Shares its subcommand list with `SandboxCommand` via `SandboxCommand.subcommandTypes`,
/// so both routes dispatch to the same operations. Plan 4 removed `SandboxCommand` from
/// the public surface; this command is now the canonical entry point.
public struct WorkspaceCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "workspace",
        abstract: L10n.Workspace.abstract,
        subcommands: SandboxCommand.subcommandTypes
    )

    public init() {}
}
