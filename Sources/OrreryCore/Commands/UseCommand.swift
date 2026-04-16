import ArgumentParser
import Foundation

public struct UseCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "use",
        abstract: L10n.Use.abstract
    )

    @Argument(help: ArgumentHelp(L10n.Use.nameHelp))
    public var name: String

    public init() {}

    public func run() throws {
        stderrWrite(L10n.Use.needsShellIntegration)
        throw ExitCode.failure
    }
}
