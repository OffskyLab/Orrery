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
        FileHandle.standardError.write(Data(L10n.Use.needsShellIntegration.utf8))
        throw ExitCode.failure
    }
}
