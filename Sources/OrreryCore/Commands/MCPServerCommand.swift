import ArgumentParser

public struct MCPServerCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mcp-server",
        abstract: L10n.MCPServerCmd.abstract,
        shouldDisplay: false
    )

    public init() {}

    public func run() async throws {
        await MCPServer.run()
    }
}
