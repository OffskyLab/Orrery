import ArgumentParser

public struct InitCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Output shell integration script (add to ~/.zshrc: eval \"$(orbital init)\")"
    )
    public init() {}

    public func run() throws {
        print(ShellFunctionGenerator.generate())
    }
}
