import ArgumentParser
import Foundation
import OrreryCore

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

    @Option(name: .long, help: ArgumentHelp(L10n.Magi.resumeHelp))
    public var resume: String?

    @Option(name: .long, help: ArgumentHelp(L10n.Magi.rolesHelp))
    public var roles: String?

    @Flag(name: .long, help: ArgumentHelp(L10n.Magi.noSummarizeHelp))
    public var noSummarize: Bool = false

    @Flag(name: .long, help: ArgumentHelp(L10n.Magi.specHelp))
    public var spec: Bool = false

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

        // Parse role assignments
        let roleAssignments: [String: MagiRole]?
        if let rolesInput = roles {
            if let preset = MagiRolePreset(rawValue: rolesInput) {
                let presetRoles = preset.roles
                var map: [String: MagiRole] = [:]
                for (i, tool) in tools.enumerated() {
                    map[tool.rawValue] = presetRoles[i % presetRoles.count]
                }
                roleAssignments = map
            } else {
                let ids = rolesInput.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let allKnownRoles = MagiRolePreset.allCases.flatMap(\.roles)
                var map: [String: MagiRole] = [:]
                for (i, tool) in tools.enumerated() {
                    guard i < ids.count else { break }
                    let id = ids[i]
                    if let known = allKnownRoles.first(where: { $0.id == id }) {
                        map[tool.rawValue] = known
                    } else {
                        map[tool.rawValue] = MagiRole(
                            id: id, label: id.capitalized,
                            instruction: "Focus on: \(id)")
                    }
                }
                roleAssignments = map
            }
        } else {
            roleAssignments = nil
        }

        let magiRun = try MagiOrchestrator.run(
            topic: topic,
            subtopics: subtopics,
            tools: tools,
            maxRounds: rounds,
            environment: envName,
            store: store,
            outputPath: output,
            previousRunId: resume,
            noSummarize: noSummarize,
            roles: roleAssignments)

        if spec {
            let report = MagiOrchestrator.generateReport(run: magiRun)
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("magi-\(magiRun.runId).md")
            try report.write(to: tempFile, atomically: true, encoding: .utf8)

            let specOutput = try SpecGenerator.generate(
                inputPath: tempFile.path,
                outputPath: nil,
                profile: nil,
                tool: nil,
                review: false,
                environment: envName,
                store: store)
            FileHandle.standardError.write(Data(("Spec generated: \(specOutput)\n").utf8))
            try? FileManager.default.removeItem(at: tempFile)
        }
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
