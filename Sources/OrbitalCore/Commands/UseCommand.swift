import ArgumentParser
import Foundation

public struct UseCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "use",
        abstract: "Activate an environment in the current shell"
    )

    @Argument(help: "Environment name")
    public var name: String

    public init() {}

    public func run() throws {
        fputs("error: 'orbital use' requires shell integration.\n", stderr)
        fputs("Run 'orbital setup' to install it, then restart your terminal.\n", stderr)
        throw ExitCode.failure
    }
}
