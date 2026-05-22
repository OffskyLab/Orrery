import ArgumentParser

/// Top-level `orrery enter <sandbox>`. The binary always throws
/// `enter.needsShellIntegration` — the actual env-var dance lives in
/// the shell function (see ShellFunctionGenerator).
public struct EnterCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "enter",
        abstract: L10n.Enter.abstract
    )

    @Argument(help: ArgumentHelp(L10n.Enter.nameHelp))
    public var name: String

    public init() {}

    public func run() throws {
        stderrWrite(L10n.Enter.needsShellIntegration)
        throw ExitCode.failure
    }
}
