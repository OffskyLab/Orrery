import ArgumentParser

public struct InitCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: L10n.Init.abstract
    )
    public init() {}

    public func run() throws {
        print(ShellFunctionGenerator.generate())
    }
}
