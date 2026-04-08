import ArgumentParser
import Foundation

public struct CreateCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new orbital environment"
    )

    @Argument(help: "Name for the new environment")
    public var name: String

    @Option(name: .shortAndLong, help: "Description for this environment")
    public var description: String = ""

    @Option(name: .long, help: "Clone tools and env vars from an existing environment")
    public var clone: String?

    public init() {}

    public func run() throws {
        let store = EnvironmentStore.default
        try Self.createEnvironment(name: name, description: description, cloneFrom: clone, store: store)
        print("Created environment: \(name)")
        if let clone { print("Cloned tools and env vars from: \(clone)") }
    }

    public static func createEnvironment(
        name: String,
        description: String,
        cloneFrom source: String?,
        store: EnvironmentStore
    ) throws {
        var env = OrbitalEnvironment(name: name, description: description)

        if let source {
            let sourceEnv = try store.load(named: source)
            env.tools = sourceEnv.tools
            env.env = sourceEnv.env
        }

        try store.save(env)
    }
}
