import ArgumentParser

public struct SetCurrentCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_set-current",
        abstract: "Internal: persist the active environment name",
        shouldDisplay: false
    )

    @Argument var name: String
    public init() {}

    public func run() throws {
        let store = EnvironmentStore.default
        try store.setCurrent(name)
    }
}
