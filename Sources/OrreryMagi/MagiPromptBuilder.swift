import Foundation
import OrreryCore

public struct MagiPromptBuilder {

    public static func buildPrompt(
        topic: String,
        subtopics: [String],
        previousRounds: [MagiRound],
        currentRound: Int,
        targetTool: Tool,
        includeOwnHistory: Bool = true,
        role: MagiRole? = nil
    ) -> String {
        var lines: [String] = []

        lines.append("## Multi-Model Discussion — Round \(currentRound)")
        lines.append("")
        lines.append("### Topic")
        lines.append(topic)
        lines.append("")
        lines.append("### Sub-topics")
        for (i, st) in subtopics.enumerated() {
            lines.append("\(i + 1). \(st)")
        }

        // Your Previous Reasoning (only for round 2+ and when includeOwnHistory is true)
        if includeOwnHistory && !previousRounds.isEmpty {
            lines.append("")
            lines.append("### Your Previous Reasoning")
            let ownOutputs = collectOwnOutputs(
                tool: targetTool, rounds: previousRounds)
            for (roundNum, output) in ownOutputs {
                lines.append("")
                lines.append("**Round \(roundNum):**")
                lines.append(output)
            }
        }

        // Other Participants' Positions
        if !previousRounds.isEmpty {
            lines.append("")
            lines.append("### Other Participants' Positions")
            let roundsToInclude = includeOwnHistory ? previousRounds : [previousRounds.last].compactMap { $0 }
            for round in roundsToInclude {
                lines.append("")
                lines.append("**Round \(round.roundNumber):**")
                for response in round.responses where response.tool != targetTool {
                    let roleLabel = response.role.map { " (\($0.label))" } ?? ""
                    if let positions = response.positions {
                        for pos in positions {
                            lines.append("- \(response.tool.rawValue)\(roleLabel): \(pos.subtopic) → \(pos.position.rawValue): \(pos.reasoning)")
                        }
                    } else {
                        lines.append("- \(response.tool.rawValue)\(roleLabel): (parse failed; no structured position available)")
                    }
                }
            }
        }

        if let role {
            lines.append("")
            lines.append("### Your Role")
            lines.append("You are \(targetTool.rawValue) acting as **\(role.label)**.")
            lines.append(role.instruction)
            lines.append("")
            lines.append("Analyze each sub-topic from this perspective. Your role shapes your priorities, not your conclusion — you can still agree or disagree with others.")
        }

        let identity = role != nil
            ? "You are \(targetTool.rawValue) (\(role!.label))."
            : "You are \(targetTool.rawValue)."

        lines.append("")
        lines.append("### Your Task")
        lines.append("""
            \(identity) Based on your previous reasoning above and other \
            participants' positions, analyze each sub-topic and provide your updated position.

            You MUST end your response with a JSON block in this exact format:
            ```json
            {"positions": [{"subtopic": "...", "position": "agree|disagree|conditional", "reasoning": "..."}]}
            ```

            If you disagree with another model's position, explain why in reasoning.
            Stay consistent with your reasoning chain unless you find a compelling counter-argument.
            """)

        return lines.joined(separator: "\n")
    }

    // MARK: - Private

    private static func collectOwnOutputs(
        tool: Tool, rounds: [MagiRound]
    ) -> [(roundNumber: Int, output: String)] {
        var results: [(Int, String)] = []
        for round in rounds {
            if let response = round.responses.first(where: { $0.tool == tool }) {
                results.append((round.roundNumber, response.rawOutput))
            }
        }
        // If cumulative raw output > 8000 chars, keep only last 2 full,
        // degrade earlier ones to positions summary
        let totalLength = results.reduce(0) { $0 + $1.1.count }
        if totalLength > 8000, results.count > 2 {
            let cutoff = results.count - 2
            for i in 0..<cutoff {
                let roundNum = results[i].0
                // Find this round's parsed positions for summary
                if let round = rounds.first(where: { $0.roundNumber == roundNum }),
                   let response = round.responses.first(where: { $0.tool == tool }) {
                    if let positions = response.positions {
                        let summary = positions.map {
                            "\($0.subtopic) → \($0.position.rawValue): \($0.reasoning)"
                        }.joined(separator: "\n")
                        results[i] = (roundNum, "[Summary]\n\(summary)")
                    } else {
                        results[i] = (roundNum, "[Summary unavailable: response was not parsed]")
                    }
                }
            }
        }
        return results
    }
}
