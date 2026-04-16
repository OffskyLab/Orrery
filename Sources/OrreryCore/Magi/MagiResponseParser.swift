import Foundation

public struct MagiResponseParser {

    private struct PositionsWrapper: Codable {
        let positions: [MagiPositionEntry]
    }

    public static func parse(
        rawOutput: String, subtopics: [String]
    ) -> (positions: [MagiPositionEntry]?, parseSuccess: Bool) {
        // Strategy 1: Find last ```json ... ``` block
        if let positions = parseJSONBlock(from: rawOutput) {
            return (positions, true)
        }

        // Strategy 2: Regex fallback
        if let positions = regexFallback(rawOutput: rawOutput, subtopics: subtopics),
           !positions.isEmpty {
            return (positions, false)
        }

        // Strategy 3: Complete failure
        return (nil, false)
    }

    // MARK: - Private

    private static func parseJSONBlock(from text: String) -> [MagiPositionEntry]? {
        // Find the last ```json ... ``` block
        let pattern = "```json\\s*\\n([\\s\\S]*?)\\n\\s*```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsString = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
        guard let lastMatch = matches.last else { return nil }
        let jsonString = nsString.substring(with: lastMatch.range(at: 1))
        guard let data = jsonString.data(using: .utf8) else { return nil }
        let wrapper = try? JSONDecoder().decode(PositionsWrapper.self, from: data)
        return wrapper?.positions
    }

    private static func regexFallback(
        rawOutput: String, subtopics: [String]
    ) -> [MagiPositionEntry]? {
        var results: [MagiPositionEntry] = []
        let lowered = rawOutput.lowercased()

        for subtopic in subtopics {
            let subtopicLower = subtopic.lowercased()
            // Search for the subtopic mention followed by a position keyword
            guard lowered.contains(subtopicLower) else { continue }

            let position: MagiPosition
            // Simple heuristic: find the position keyword nearest to the subtopic
            if let range = lowered.range(of: subtopicLower) {
                let after = String(lowered[range.upperBound...].prefix(200))
                if after.contains("disagree") {
                    position = .disagree
                } else if after.contains("conditional") {
                    position = .conditional
                } else if after.contains("agree") {
                    position = .agree
                } else {
                    continue
                }
            } else {
                continue
            }

            results.append(MagiPositionEntry(
                subtopic: subtopic,
                position: position,
                reasoning: "extracted from unstructured output"))
        }
        return results.isEmpty ? nil : results
    }
}
