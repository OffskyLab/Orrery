import ArgumentParser
import Foundation

public struct MagiCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "magi",
        abstract: L10n.Magi.abstract
    )

    @Flag(help: ArgumentHelp(L10n.ToolFlag.claude))
    public var claude: Bool = false

    @Flag(help: ArgumentHelp(L10n.ToolFlag.codex))
    public var codex: Bool = false

    @Flag(help: ArgumentHelp(L10n.ToolFlag.gemini))
    public var gemini: Bool = false

    @Option(name: .shortAndLong, help: ArgumentHelp(L10n.Magi.envHelp))
    public var environment: String?

    @Option(name: .long, help: ArgumentHelp(L10n.Magi.roundsHelp))
    public var rounds: Int = 3

    @Option(name: .long, help: ArgumentHelp(L10n.Magi.outputHelp))
    public var output: String?

    @Argument(help: ArgumentHelp(L10n.Magi.topicHelp))
    public var topic: String

    public init() {}

    public func run() throws {
        let store = EnvironmentStore.default
        let envName = environment ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]

        // Determine participating tools
        var tools: [Tool] = []
        if claude { tools.append(.claude) }
        if codex { tools.append(.codex) }
        if gemini { tools.append(.gemini) }
        if tools.isEmpty { tools = Tool.allCases.map { $0 } }

        // Filter to available tools
        tools = tools.filter { isToolAvailable($0) }
        guard tools.count >= 2 else {
            throw ValidationError(L10n.Magi.insufficientTools)
        }

        // Split topic into subtopics by semicolons
        let subtopics = topic.components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        _ = try MagiOrchestrator.run(
            topic: topic,
            subtopics: subtopics,
            tools: tools,
            maxRounds: rounds,
            environment: envName,
            store: store,
            outputPath: output)
    }

    private func isToolAvailable(_ tool: Tool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", tool.rawValue]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
