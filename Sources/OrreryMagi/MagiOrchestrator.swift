import ArgumentParser
import Foundation
import OrreryCore

public struct MagiOrchestrator {

    public static func run(
        topic: String,
        subtopics: [String],
        tools: [Tool],
        maxRounds: Int,
        environment: String?,
        store: EnvironmentStore,
        outputPath: String?,
        previousRunId: String? = nil,
        noSummarize: Bool = false,
        roles: [String: MagiRole]? = nil
    ) throws -> MagiRun {
        let now = ISO8601DateFormatter().string(from: Date())
        var magiRun = MagiRun(
            runId: UUID().uuidString,
            topic: topic,
            participants: tools,
            roleAssignments: roles,
            environment: environment,
            rounds: [],
            finalConsensus: nil,
            sessionMap: nil,
            finalVerdict: nil,
            status: .inProgress,
            createdAt: now,
            updatedAt: now)

        // Load previous run for session resume
        var sessionMap: [String: String] = [:]
        var previousRounds: [MagiRound] = []
        if let previousRunId {
            let previousFile = store.homeURL
                .appendingPathComponent("magi")
                .appendingPathComponent("\(previousRunId).json")
            guard FileManager.default.fileExists(atPath: previousFile.path) else {
                throw ValidationError("Previous run not found: \(previousRunId)")
            }
            let data = try Data(contentsOf: previousFile)
            let previousRun = try JSONDecoder().decode(MagiRun.self, from: data)
            sessionMap = previousRun.sessionMap ?? [:]
            previousRounds = previousRun.rounds
            stderr(L10n.Magi.resuming(previousRunId))
        }

        for roundNumber in 1...maxRounds {
            stderr(L10n.Magi.roundStart(roundNumber, maxRounds))

            let allPreviousRounds = previousRounds + magiRun.rounds

            // Launch all tools in parallel
            let group = DispatchGroup()
            let resultQueue = DispatchQueue(label: "magi.results")
            var runnerResults: [AgentExecutionResult] = []

            for tool in tools {
                group.enter()
                DispatchQueue.global().async {
                    defer { group.leave() }

                    let resumeId = sessionMap[tool.rawValue]
                    let includeOwn = (resumeId == nil)
                    let role = roles?[tool.rawValue]
                    let prompt = MagiPromptBuilder.buildPrompt(
                        topic: topic,
                        subtopics: subtopics,
                        previousRounds: allPreviousRounds,
                        currentRound: (previousRounds.count + roundNumber),
                        targetTool: tool,
                        includeOwnHistory: includeOwn,
                        role: role)

                    if let role {
                        stderr(L10n.Magi.roleAssigned(tool.rawValue, role.label))
                    }
                    stderr(L10n.Magi.toolStart(tool.rawValue))

                    // Post-M5a: Magi no longer owns the subprocess plumbing;
                    // `ProcessAgentExecutor` is the single path through
                    // `DelegateProcessBuilder` + session snapshot-diff.
                    let executor = ProcessAgentExecutor(
                        store: store, activeEnvironment: environment)
                    let request = AgentExecutionRequest(
                        tool: tool, prompt: prompt,
                        resumeSessionId: resumeId,
                        timeout: 120)
                    let result: AgentExecutionResult
                    do {
                        result = try executor.execute(request: request)
                    } catch {
                        // Launch-level failure surfaces as an exception
                        // from AgentExecutor; fall back to the same
                        // "failed" shape the orchestrator expects.
                        result = AgentExecutionResult(
                            tool: tool, rawOutput: "",
                            stderrOutput: "Build failed: \(error)",
                            exitCode: -1, timedOut: false, sessionId: nil,
                            duration: 0)
                    }

                    if result.timedOut {
                        stderr(L10n.Magi.timeoutWarning(tool.rawValue, 120))
                    }

                    resultQueue.sync { runnerResults.append(result) }
                }
            }
            group.wait()

            // Convert runner results to MagiAgentResponses
            var responses: [MagiAgentResponse] = []
            for result in runnerResults {
                let (positions, parseSuccess) = MagiResponseParser.parse(
                    rawOutput: result.rawOutput, subtopics: subtopics)
                let parseStatus = parseSuccess ? "parsed" : "fallback"
                stderr(L10n.Magi.toolDone(result.tool.rawValue, parseStatus))

                responses.append(MagiAgentResponse(
                    tool: result.tool,
                    role: roles?[result.tool.rawValue],
                    rawOutput: result.rawOutput,
                    positions: positions, votes: nil,
                    parseSuccess: parseSuccess,
                    exitCode: result.exitCode,
                    stderrOutput: result.stderrOutput.isEmpty ? nil : result.stderrOutput,
                    timedOut: result.timedOut,
                    duration: result.duration,
                    sessionId: result.sessionId))

                // Update session map
                if let sid = result.sessionId {
                    sessionMap[result.tool.rawValue] = sid
                }
            }

            let consensusSnapshot = computeConsensus(
                responses: responses, subtopics: subtopics)
            let round = MagiRound(
                roundNumber: previousRounds.count + roundNumber,
                responses: responses,
                consensusSnapshot: consensusSnapshot, votes: nil)
            magiRun.rounds.append(round)
            magiRun.sessionMap = sessionMap.isEmpty ? nil : sessionMap
            magiRun.updatedAt = ISO8601DateFormatter().string(from: Date())
            try magiRun.save(store: store)
        }

        magiRun.status = .maxRoundsReached
        magiRun.finalConsensus = magiRun.rounds.last?.consensusSnapshot

        // Generate FinalVerdict
        let verdict: FinalVerdict
        if !noSummarize {
            stderr(L10n.Magi.summarizing)
            if let summarized = try? generateSummarizedVerdict(
                run: magiRun, tools: tools, environment: environment, store: store) {
                verdict = summarized
            } else {
                verdict = generateCodeMergedVerdict(run: magiRun, subtopics: subtopics)
            }
        } else {
            verdict = generateCodeMergedVerdict(run: magiRun, subtopics: subtopics)
        }
        magiRun.finalVerdict = verdict

        magiRun.updatedAt = ISO8601DateFormatter().string(from: Date())
        try magiRun.save(store: store)

        let report = generateReport(run: magiRun)
        // stdout: only final report + Run ID
        print(report)
        print("\nRun ID: \(magiRun.runId)")

        if let outputPath {
            do {
                try report.write(toFile: outputPath, atomically: true, encoding: .utf8)
                stderr(L10n.Magi.runSaved(outputPath))
            } catch {
                stderr("Warning: could not write to \(outputPath): \(error)")
            }
        }

        let savePath = store.homeURL
            .appendingPathComponent("magi")
            .appendingPathComponent("\(magiRun.runId).json").path
        stderr(L10n.Magi.runSaved(savePath))

        return magiRun
    }

    // MARK: - Helpers

    private static func stderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    // MARK: - FinalVerdict Generation

    private static func generateSummarizedVerdict(
        run: MagiRun, tools: [Tool], environment: String?, store: EnvironmentStore
    ) throws -> FinalVerdict {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let runJSON = String(data: try encoder.encode(run), encoding: .utf8) ?? ""

        let prompt = """
            You are a facilitator summarizing a multi-model discussion.
            Below is the full discussion data in JSON format.

            Your task: produce a FinalVerdict JSON that synthesizes all positions into clear decisions.
            For each subtopic, merge agreeing positions into a single summary (no redundancy),
            note any dissenting view, and identify open questions and constraints.

            Output ONLY valid JSON in this exact format (no markdown, no explanation):
            {"decisions":[{"subtopic":"...","status":"agreed|majority|disputed|pending","summary":"...","reasoning":"...","dissent":"...or null"}],"openQuestions":["..."],"constraints":["..."]}

            Discussion data:
            \(runJSON)
            """

        let facilitator = tools[0]
        let builder = DelegateProcessBuilder(
            tool: facilitator, prompt: prompt,
            resumeSessionId: nil,
            environment: environment, store: store)
        let (process, _, outputPipe) = try builder.build(outputMode: .capture)

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        // Read before wait to avoid deadlock
        var stdoutData = Data()
        let readQueue = DispatchQueue(label: "magi.summarize.read")
        let readGroup = DispatchGroup()
        readGroup.enter()
        readQueue.async {
            if let pipe = outputPipe {
                stdoutData = pipe.fileHandleForReading.readDataToEndOfFile()
            }
            readGroup.leave()
        }
        // Drain stderr to prevent blocking
        let stderrReadGroup = DispatchGroup()
        stderrReadGroup.enter()
        DispatchQueue.global().async {
            _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrReadGroup.leave()
        }

        try process.run()
        process.waitUntilExit()
        readGroup.wait()
        stderrReadGroup.wait()

        let output = String(data: stdoutData, encoding: .utf8) ?? ""

        // Try to extract JSON from the output
        guard let jsonStart = output.range(of: "{\"decisions\""),
              let jsonData = output[jsonStart.lowerBound...].data(using: .utf8) else {
            throw NSError(domain: "MagiOrchestrator", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No valid FinalVerdict JSON found"])
        }

        return try JSONDecoder().decode(FinalVerdict.self, from: jsonData)
    }

    private static func generateCodeMergedVerdict(
        run: MagiRun, subtopics: [String]
    ) -> FinalVerdict {
        guard let consensus = run.finalConsensus else {
            return FinalVerdict(decisions: [], openQuestions: [], constraints: [])
        }

        var decisions: [VerdictDecision] = []
        var openQuestions: [String] = []
        var constraints: [String] = []

        for item in consensus {
            // Find the best reasoning from the last round's responses
            let lastRound = run.rounds.last
            var summary = ""
            var reasoning = ""
            var dissent: String? = nil

            if let responses = lastRound?.responses {
                // Find agreeing positions for summary
                let agreeing = responses.filter { resp in
                    resp.positions?.first(where: { $0.subtopic == item.subtopic })?.position != .disagree
                }
                if let first = agreeing.first,
                   let pos = first.positions?.first(where: { $0.subtopic == item.subtopic }) {
                    summary = pos.reasoning
                    reasoning = "\(first.tool.rawValue): \(pos.reasoning)"
                }

                // Find dissenting positions
                let dissenting = responses.filter { resp in
                    resp.positions?.first(where: { $0.subtopic == item.subtopic })?.position == .disagree
                }
                if let first = dissenting.first,
                   let pos = first.positions?.first(where: { $0.subtopic == item.subtopic }) {
                    dissent = "\(first.tool.rawValue): \(pos.reasoning)"
                }

                // Collect constraints from conditional positions
                let conditionals = responses.compactMap { resp -> String? in
                    guard let pos = resp.positions?.first(where: { $0.subtopic == item.subtopic }),
                          pos.position == .conditional else { return nil }
                    return "\(resp.tool.rawValue): \(pos.reasoning)"
                }
                constraints.append(contentsOf: conditionals)
            }

            if item.status == .disputed {
                openQuestions.append(item.subtopic)
            }

            decisions.append(VerdictDecision(
                subtopic: item.subtopic,
                status: item.status,
                summary: summary,
                reasoning: reasoning,
                dissent: dissent))
        }

        return FinalVerdict(
            decisions: decisions,
            openQuestions: openQuestions,
            constraints: constraints)
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

    public static func generateReport(run: MagiRun) -> String {
        var lines: [String] = []
        lines.append("# \(L10n.Magi.consensusReport)")
        lines.append("")
        lines.append("**Topic**: \(run.topic)")
        lines.append("**Participants**: \(run.participants.map(\.rawValue).joined(separator: ", "))")
        if let assignments = run.roleAssignments {
            let roleDesc = run.participants.compactMap { tool in
                assignments[tool.rawValue].map { "\(tool.rawValue) (\($0.label))" }
            }.joined(separator: ", ")
            lines.append("**Roles**: \(roleDesc)")
        }
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
                let roleLabel = response.role.map { " (\($0.label))" } ?? ""
                lines.append("#### \(response.tool.rawValue)\(roleLabel)")
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

        // Final Verdict section
        if let verdict = run.finalVerdict, !verdict.decisions.isEmpty {
            lines.append("")
            lines.append("## Final Verdict")
            for decision in verdict.decisions {
                lines.append("")
                lines.append("### \(decision.subtopic) [\(decision.status.rawValue)]")
                lines.append(decision.summary)
                if let dissent = decision.dissent {
                    lines.append("")
                    lines.append("**Dissent**: \(dissent)")
                }
            }
            if !verdict.openQuestions.isEmpty {
                lines.append("")
                lines.append("### Open Questions")
                for q in verdict.openQuestions {
                    lines.append("- \(q)")
                }
            }
            if !verdict.constraints.isEmpty {
                lines.append("")
                lines.append("### Constraints")
                for c in verdict.constraints {
                    lines.append("- \(c)")
                }
            }
        }

        lines.append("")
        lines.append("---")
        lines.append("*This report reflects model consensus, not verified facts.*")
        return lines.joined(separator: "\n")
    }
}
