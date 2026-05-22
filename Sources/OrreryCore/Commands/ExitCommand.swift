import ArgumentParser
import Foundation

/// Top-level `orrery exit`. Same shape as EnterCommand: the binary
/// throws needsShellIntegration; the shell function does the work.
public struct ExitCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "exit",
        abstract: L10n.Exit.abstract
    )

    public init() {}

    public func run() throws {
        // enter.needsShellIntegration is shared with enter — both verbs
        // need the shell wrapper to mutate env vars.
        stderrWrite(L10n.Enter.needsShellIntegration)
        throw ExitCode.failure
    }
}
