import ArgumentParser

public struct MCPServerCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mcp-server",
        abstract: L10n.MCPServerCmd.abstract,
        shouldDisplay: false
    )

    public init() {}

    public func run() throws {
        MCPServer.run()
    }
}
