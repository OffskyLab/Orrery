import Foundation

public struct MagiOrchestrator {

    public static func run(
        topic: String,
        subtopics: [String],
        tools: [Tool],
        maxRounds: Int,
        environment: String?,
        store: EnvironmentStore,
        outputPath: String?
    ) throws -> MagiRun {
        let now = ISO8601DateFormatter().string(from: Date())
        var magiRun = MagiRun(
            runId: UUID().uuidString,
            topic: topic,
            participants: tools,
            environment: environment,
            rounds: [],
            finalConsensus: nil,
            status: .inProgress,
            createdAt: now,
            updatedAt: now)

        for roundNumber in 1...maxRounds {
            print(L10n.Magi.roundStart(roundNumber, maxRounds))
            var responses: [MagiAgentResponse] = []

            for tool in tools {
                print(L10n.Magi.toolStart(tool.rawValue))

                let prompt = MagiPromptBuilder.buildPrompt(
                    topic: topic,
                    subtopics: subtopics,
                    previousRounds: magiRun.rounds,
                    currentRound: roundNumber,
                    targetTool: tool)

                let response: MagiAgentResponse
                do {
                    let builder = DelegateProcessBuilder(
                        tool: tool, prompt: prompt,
                        resumeSessionId: nil,
                        environment: environment, store: store)
                    let (process, _, outputPipe) = try builder.build(outputMode: .capture)
                    try process.run()
                    process.waitUntilExit()

                    let rawOutput: String
                    if let pipe = outputPipe {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        rawOutput = String(data: data, encoding: .utf8) ?? ""
                    } else {
                        rawOutput = ""
                    }

                    let (positions, parseSuccess) = MagiResponseParser.parse(
                        rawOutput: rawOutput, subtopics: subtopics)
                    let parseStatus = parseSuccess ? "parsed" : "fallback"
                    print(L10n.Magi.toolDone(tool.rawValue, parseStatus))
                    response = MagiAgentResponse(
                        tool: tool, rawOutput: rawOutput,
                        positions: positions, votes: nil,
                        parseSuccess: parseSuccess)
                } catch {
                    print(L10n.Magi.toolDone(tool.rawValue, "error"))
                    response = MagiAgentResponse(
                        tool: tool, rawOutput: "",
                        positions: nil, votes: nil,
                        parseSuccess: false)
                }
                responses.append(response)
            }

            let consensusSnapshot = computeConsensus(
                responses: responses, subtopics: subtopics)
            let round = MagiRound(
                roundNumber: roundNumber, responses: responses,
                consensusSnapshot: consensusSnapshot, votes: nil)
            magiRun.rounds.append(round)
            magiRun.updatedAt = ISO8601DateFormatter().string(from: Date())
            try? magiRun.save(store: store)
        }

        magiRun.status = .maxRoundsReached
        magiRun.finalConsensus = magiRun.rounds.last?.consensusSnapshot
        magiRun.updatedAt = ISO8601DateFormatter().string(from: Date())
        try? magiRun.save(store: store)

        let report = generateReport(run: magiRun)
        print(report)

        if let outputPath {
            do {
                try report.write(toFile: outputPath, atomically: true, encoding: .utf8)
                FileHandle.standardError.write(
                    Data((L10n.Magi.runSaved(outputPath) + "\n").utf8))
            } catch {
                FileHandle.standardError.write(
                    Data("Warning: could not write to \(outputPath): \(error)\n".utf8))
            }
        }

        let savePath = store.homeURL
            .appendingPathComponent("magi")
            .appendingPathComponent("\(magiRun.runId).json").path
        FileHandle.standardError.write(
            Data((L10n.Magi.runSaved(savePath) + "\n").utf8))

        return magiRun
    }

    // MARK: - Consensus

    private static func computeConsensus(
        responses: [MagiAgentResponse], subtopics: [String]
    ) -> [ConsensusItem] {
        subtopics.map { subtopic in
            var positionMap: [String: MagiPosition] = [:]
            for response in responses {
                if let positions = response.positions,
                   let entry = positions.first(where: { $0.subtopic == subtopic }) {
                    positionMap[response.tool.rawValue] = entry.position
                }
            }

            let status: ConsensusStatus
            let values = Array(positionMap.values)
            if values.count < 2 {
                status = .pending
            } else if values.allSatisfy({ $0 == .agree }) {
                status = .agreed
            } else {
                let agreeCount = values.filter { $0 == .agree || $0 == .conditional }.count
                let disagreeCount = values.filter { $0 == .disagree }.count
                if agreeCount >= 2 && disagreeCount <= 1 {
                    status = .majority
                } else if disagreeCount >= 2 {
                    status = .disputed
                } else {
                    status = .disputed
                }
            }

            return ConsensusItem(
                subtopic: subtopic, status: status, positions: positionMap)
        }
    }

    // MARK: - Report

    private static func generateReport(run: MagiRun) -> String {
        var lines: [String] = []
        lines.append("# \(L10n.Magi.consensusReport)")
        lines.append("")
        lines.append("**Topic**: \(run.topic)")
        lines.append("**Participants**: \(run.participants.map(\.rawValue).joined(separator: ", "))")
        lines.append("**Rounds**: \(run.rounds.count)")
        lines.append("**Date**: \(run.createdAt)")
        lines.append("")
        lines.append("## Consensus")
        lines.append("")
        lines.append("| Sub-topic | Status | Details |")
        lines.append("|-----------|--------|---------|")

        if let consensus = run.finalConsensus {
            for item in consensus {
                let details = item.positions.map { "\($0.key): \($0.value.rawValue)" }
                    .joined(separator: ", ")
                lines.append("| \(item.subtopic) | \(item.status.rawValue) | \(details) |")
            }
        }

        lines.append("")
        lines.append("## Round Details")

        for round in run.rounds {
            lines.append("")
            lines.append("### Round \(round.roundNumber)")
            for response in round.responses {
                lines.append("")
                lines.append("#### \(response.tool.rawValue)")
                let excerpt = String(response.rawOutput.prefix(500))
                lines.append(excerpt)
                if let positions = response.positions {
                    lines.append("")
                    lines.append("**Positions**:")
                    for pos in positions {
                        lines.append("- \(pos.subtopic): \(pos.position.rawValue) — \(pos.reasoning)")
                    }
                }
            }
        }

        lines.append("")
        lines.append("---")
        lines.append("*This report reflects model consensus, not verified facts.*")
        return lines.joined(separator: "\n")
    }
}
