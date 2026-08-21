import Foundation

/// Records *which tools* a one-shot migration actually covered, rather than a
/// single global "done" marker.
///
/// The bare marker is safe only while the tool list is fixed at compile time.
/// Once `Tool.allCases` becomes a registry — total only if registration ran —
/// a tool that was not registered when the migration executed gets skipped and
/// the flag is written anyway, so it never migrates on that machine again. The
/// failure is invisible and permanent, which is why this exists before any
/// call site moves.
///
/// File format is a version line followed by one tool id per line:
///
///     v2
///     claude
///     codex
///
/// A file with no id lines is a pre-existing marker (`v1` / `v3`) written
/// before this type existed. Those are read as covering everything: the
/// migration genuinely did run for every tool that existed then, and treating
/// them as covering nothing would re-run every migration on upgrade.
public struct MigrationFlag {
    public enum Coverage: Equatable {
        /// No flag file — the migration has never run.
        case absent
        /// A pre-per-tool marker. Counts as covering every tool.
        case legacyCoversAll
        /// The tool ids this migration has covered.
        case ids(Set<String>)
    }

    private static let formatVersion = "v2"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func coverage() -> Coverage {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return .absent }

        let ids = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != Self.formatVersion && !isVersionToken($0) }

        return ids.isEmpty ? .legacyCoversAll : .ids(Set(ids))
    }

    /// Which of `candidates` this migration has not yet covered.
    public func pending(among candidates: Set<String>) -> Set<String> {
        switch coverage() {
        case .absent:         return candidates
        case .legacyCoversAll: return []
        case .ids(let done):  return candidates.subtracting(done)
        }
    }

    /// Adds `ids` to the covered set. Unions rather than replaces, so a
    /// migration that runs for one late-registered tool does not erase the
    /// record of the tools it already handled.
    public func markCovered(_ ids: Set<String>) throws {
        var all = ids
        if case .ids(let existing) = coverage() {
            all.formUnion(existing)
        }
        let body = ([Self.formatVersion] + all.sorted()).joined(separator: "\n") + "\n"
        try Data(body.utf8).write(to: url, options: .atomic)
    }

    /// `v1`, `v3`, … — a legacy marker line, not a tool id.
    private func isVersionToken(_ s: String) -> Bool {
        s.first == "v" && s.dropFirst().allSatisfy(\.isNumber) && s.count > 1
    }
}
