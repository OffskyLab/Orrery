import Foundation

/// Append-only JSON Lines log that delegate agents emit during
/// `orrery spec-run --mode implement`. Each line is a single JSON object
/// encoding one step-boundary event.
///
/// Design (DI8)：delegate 靠 Bash / Write 工具 append 進 `$ORRERY_SPEC_PROGRESS_LOG`；
/// `_spec-finalize` 讀檔、推斷 failed_step / completed_steps，過程中遇到壞行
/// 一律 **skip**、不讓整體 fail（fallback：`failedStep = nil` 並於 stderr 標註）。
///
/// Schema per line:
/// ```json
/// { "ts": "2026-04-20T12:00:00Z", "step": "step-1", "event": "start", "note": "optional" }
/// ```
/// Allowed event values: `"start"` / `"done"` / `"skip"`.
public struct SpecProgressLog {

    public struct Event: Codable, Equatable {
        public let ts: String
        public let step: String
        public let event: String
        public let note: String?

        public init(ts: String, step: String, event: String, note: String? = nil) {
            self.ts = ts
            self.step = step
            self.event = event
            self.note = note
        }
    }

    // MARK: - Append

    /// Append one event to the jsonl file, creating parent directories and
    /// the file itself as needed. Never pretty-prints.
    public static func append(path: String, event: Event) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        // Explicit null for missing note keeps shape stable for downstream
        // tooling that may prefer consistent keys.
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(event)
        let line = (String(data: data, encoding: .utf8) ?? "") + "\n"

        if FileManager.default.fileExists(atPath: path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } else {
            try line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Read

    /// Read all valid events from the log. Missing file → `[]`. Bad lines
    /// (malformed JSON, wrong shape) are silently skipped so a single
    /// corruption cannot break `_spec-finalize`.
    public static func read(path: String) throws -> [Event] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        return parseLines(content)
    }

    // MARK: - Inference helpers

    /// Scan events in order and find the most recent `start` event that has
    /// no subsequent `done` or `skip` event for the same `step`. Returns
    /// that step name, or `nil` if every started step has a matching
    /// completion event.
    public static func inferFailedStep(events: [Event]) -> String? {
        // Walk forward, tracking the last open step. If we see a `done`/`skip`
        // matching the open step, clear it. The final value of `openStep` is
        // the first unterminated start.
        var openStep: String? = nil
        for e in events {
            switch e.event {
            case "start":
                openStep = e.step
            case "done", "skip":
                if openStep == e.step {
                    openStep = nil
                }
            default:
                continue
            }
        }
        return openStep
    }

    /// Return step names in the order they received a `done` event.
    /// Duplicates (same step done twice) are preserved.
    public static func completedSteps(events: [Event]) -> [String] {
        events.filter { $0.event == "done" }.map { $0.step }
    }

    // MARK: - Tail

    /// Return the last `lines` raw jsonl lines from the file (after optional
    /// `since` filtering by `ts`). Returns original line strings — does NOT
    /// re-serialize, so the caller's view is byte-identical to what delegate
    /// wrote (modulo trailing `\n` stripping).
    public static func tail(path: String, lines: Int, since: String?) throws -> [String] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let allLines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        let filtered: [String]
        if let since = since {
            filtered = allLines.filter { line in
                guard let data = line.data(using: .utf8),
                      let event = try? JSONDecoder().decode(Event.self, from: data) else {
                    // bad line → drop silently (consistent with read())
                    return false
                }
                // ISO8601 sorts lexicographically when Z-normalised; MVP
                // assumes delegate emits UTC / Z-terminated timestamps. If
                // caller passes a non-Z timestamp, comparison stays stable
                // but may be mildly surprising at DST boundaries — document
                // in tool description.
                return event.ts > since
            }
        } else {
            filtered = allLines
        }

        guard lines > 0 else { return [] }
        return Array(filtered.suffix(lines))
    }

    // MARK: - Internal

    private static func parseLines(_ content: String) -> [Event] {
        content.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(Event.self, from: data)
        }
    }
}
