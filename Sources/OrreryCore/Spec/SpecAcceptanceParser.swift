import ArgumentParser
import Foundation

/// Parser that extracts checklist items and executable bash commands from the
/// "## 驗收標準" (or "## Acceptance Criteria") section of a spec markdown file.
///
/// Scope: read-only parser — never executes any command. Preserves order,
/// does not deduplicate. See docs/tasks/2026-04-18-orrery-spec-mcp-tool.md §4.
public struct SpecAcceptanceParser {
    public struct ChecklistItem: Equatable {
        public let text: String
        public init(text: String) { self.text = text }
    }

    public struct Command: Equatable {
        public let line: String
        public init(line: String) { self.line = line }
    }

    public static func parse(markdown: String) throws -> (
        checklist: [ChecklistItem],
        commands: [Command]
    ) {
        let lines = markdown.components(separatedBy: "\n")

        guard let headingIndex = findAcceptanceHeading(lines: lines) else {
            throw ValidationError(L10n.SpecRun.missingAcceptanceSection)
        }

        let sectionLines = extractSection(lines: lines, from: headingIndex + 1)

        var checklist: [ChecklistItem] = []
        var commands: [Command] = []
        var inFence = false
        var pending: String? = nil

        // Heredoc state. When non-nil, the parser is consuming a heredoc body
        // until it sees `terminator` as its own (optionally tab-stripped) line.
        var heredocTerminator: String? = nil
        var heredocStripTabs = false
        var heredocLines: [String] = []

        for rawLine in sectionLines {
            // --- Heredoc body accumulation (inside a fence, body lines are preserved verbatim) ---
            if let terminator = heredocTerminator {
                heredocLines.append(rawLine)
                let candidate = heredocStripTabs
                    ? String(rawLine.drop(while: { $0 == "\t" }))
                    : rawLine
                if candidate == terminator {
                    // End of heredoc — emit the whole block as one Command.
                    let merged = heredocLines.joined(separator: "\n")
                    if !merged.hasPrefix("#") {
                        commands.append(Command(line: merged))
                    }
                    heredocLines = []
                    heredocTerminator = nil
                    heredocStripTabs = false
                }
                continue
            }

            if !inFence {
                if isFenceOpen(rawLine) {
                    inFence = true
                    continue
                }
                if let item = matchChecklist(rawLine) {
                    checklist.append(ChecklistItem(text: item))
                }
                continue
            }

            // inFence == true
            if isFenceClose(rawLine) {
                // Flush any pending continuation as a normal command before closing.
                if let line = pending, !line.hasPrefix("#") {
                    commands.append(Command(line: line))
                }
                pending = nil
                inFence = false
                continue
            }

            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Merge into pending continuation if any.
            let merged: String
            if let prior = pending {
                merged = prior + " " + trimmed
            } else {
                merged = trimmed
            }

            if merged.hasSuffix("\\") {
                // Drop the trailing backslash and buffer.
                let stripped = String(merged.dropLast()).trimmingCharacters(in: .whitespaces)
                pending = stripped
                continue
            }

            // Heredoc opener detection on the (possibly backslash-merged) line.
            // Recognises: <<EOF / <<'EOF' / <<"EOF" / <<-EOF (strip leading tabs on terminator).
            if let opener = detectHeredocOpener(in: merged) {
                heredocTerminator = opener.delimiter
                heredocStripTabs = opener.stripTabs
                heredocLines = [merged]
                pending = nil
                continue
            }

            if !merged.hasPrefix("#") {
                commands.append(Command(line: merged))
            }
            pending = nil
        }

        // Fence left unclosed at EOF: flush pending or in-progress heredoc if present.
        if heredocTerminator != nil {
            let merged = heredocLines.joined(separator: "\n")
            if !merged.hasPrefix("#") {
                commands.append(Command(line: merged))
            }
        }
        if inFence, let line = pending, !line.hasPrefix("#") {
            commands.append(Command(line: line))
        }

        return (checklist, commands)
    }

    // MARK: - Helpers

    /// Find the first `## 驗收標準` / `## Acceptance Criteria` heading.
    private static func findAcceptanceHeading(lines: [String]) -> Int? {
        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "## 驗收標準" || trimmed == "## Acceptance Criteria" {
                return idx
            }
        }
        return nil
    }

    /// Return lines from `start` up to (but not including) the next `## ` heading.
    private static func extractSection(lines: [String], from start: Int) -> [String] {
        var end = lines.count
        var i = start
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("## ") {
                end = i
                break
            }
            i += 1
        }
        return Array(lines[start..<end])
    }

    /// Match `- [ ] <text>` / `- [x] <text>` / `- [X] <text>`. Returns the text group.
    private static func matchChecklist(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let markers = ["- [ ] ", "- [x] ", "- [X] "]
        for marker in markers {
            if trimmed.hasPrefix(marker) {
                let text = String(trimmed.dropFirst(marker.count))
                return text.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Match opening fence: ``` / ```bash / ```sh (trailing whitespace tolerated).
    private static func isFenceOpen(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "```" || trimmed == "```bash" || trimmed == "```sh"
    }

    /// Match closing fence: ``` only.
    private static func isFenceClose(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "```"
    }

    // MARK: - Structural validation (DI5 safety net for implement phase)

    /// Verifies that a spec markdown contains all four mandatory `##` headings
    /// required by DI5 (介面合約 / 改動檔案 / 實作步驟 / 驗收標準).
    ///
    /// Each heading accepts:
    /// - the canonical Chinese form (`## 介面合約`)
    /// - the same Chinese form with a parenthetical English annotation
    ///   (`## 介面合約（Interface Contract）`)
    /// - a pure English form (`## Interface Contract`)
    ///
    /// Ordering of the four checks is stable: the first missing heading
    /// encountered (by the order Interface → Changed Files → Implementation
    /// → Acceptance) determines which error is thrown, so test fixtures can
    /// assert a specific key.
    public static func validateStructure(markdown: String) throws {
        let lines = markdown.components(separatedBy: "\n")
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }

        if !containsHeading(trimmed, variants: [
            "## 介面合約",
            "## Interface Contract"
        ]) {
            throw ValidationError(L10n.SpecRun.missingInterfaceContractSection)
        }

        if !containsHeading(trimmed, variants: [
            "## 改動檔案",
            "## Changed Files"
        ]) {
            throw ValidationError(L10n.SpecRun.missingChangedFilesSection)
        }

        if !containsHeading(trimmed, variants: [
            "## 實作步驟",
            "## Implementation Steps"
        ]) {
            throw ValidationError(L10n.SpecRun.missingImplementationStepsSection)
        }

        if !containsHeading(trimmed, variants: [
            "## 驗收標準",
            "## Acceptance Criteria"
        ]) {
            throw ValidationError(L10n.SpecRun.missingAcceptanceSection)
        }
    }

    /// A line matches if it is exactly equal to any variant OR begins with a
    /// variant followed by `（` (full-width) or `(` (half-width) — supporting
    /// parenthetical English annotations like `## 介面合約（Interface Contract）`.
    private static func containsHeading(_ trimmedLines: [String], variants: [String]) -> Bool {
        for line in trimmedLines {
            for variant in variants {
                if line == variant { return true }
                if line.hasPrefix(variant + "（") { return true }
                if line.hasPrefix(variant + "(") { return true }
                if line.hasPrefix(variant + " ") { return true }  // tolerate trailing inline text
            }
        }
        return false
    }

    /// Detect a bash heredoc opener like `<<EOF`, `<<'EOF'`, `<<"EOF"`, `<<-EOF`.
    /// Returns the delimiter word and whether the terminator line will have
    /// leading tabs stripped (the `-` modifier).
    ///
    /// Limitation: this is a regex heuristic, not a full shell parser. A `<<WORD`
    /// appearing inside a quoted string (e.g. `python3 -c 'x = "<<WORD"'`) will
    /// false-positive. Acceptance specs should avoid literal `<<` inside quotes.
    private static func detectHeredocOpener(in line: String) -> (delimiter: String, stripTabs: Bool)? {
        // Pattern: `<<` + optional `-` + optional matching single/double quote
        // around a delimiter `\w+`. Captures: 1=dash, 2=open-quote, 3=word.
        let pattern = #"<<(-?)(['"]?)(\w+)\2"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range) else {
            return nil
        }
        guard match.numberOfRanges >= 4,
              let dashRange = Range(match.range(at: 1), in: line),
              let wordRange = Range(match.range(at: 3), in: line) else {
            return nil
        }
        let stripTabs = !line[dashRange].isEmpty
        let delim = String(line[wordRange])
        return (delim, stripTabs)
    }
}
