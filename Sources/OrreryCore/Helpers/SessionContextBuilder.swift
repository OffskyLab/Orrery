import Foundation

public struct SessionContextBuilder {
    public static func buildPrompt(
        turns: [SessionTurn],
        newPrompt: String,
        sessionName: String,
        maxTokenBudget: Int = 76_000
    ) -> String {
        guard !turns.isEmpty else { return newPrompt }

        // Select recent turns fitting budget (newest first)
        var selected: [SessionTurn] = []
        var usedTokens = 0
        for turn in turns.reversed() {
            if usedTokens + turn.tokenEstimate > maxTokenBudget { break }
            selected.insert(turn, at: 0)
            usedTokens += turn.tokenEstimate
        }

        guard !selected.isEmpty else { return newPrompt }

        var preamble = "<session_history name=\"\(sessionName)\">\n"
        for turn in selected {
            let label = turn.role == "user" ? "[User]" : "[Assistant]"
            preamble += "\(label) \(turn.content)\n"
        }
        preamble += "</session_history>\n\n"
        preamble += "Continue from the above conversation. New task:\n"
        preamble += newPrompt

        return preamble
    }
}
