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
/// Line 1 is always the format/version marker, whatever text it holds — tool
/// ids are never looked for there, so an id shaped like a version token (e.g.
/// `v2`) is never mistaken for one.
///
/// ## Legacy markers
///
/// A file with no non-empty lines after line 1 is a pre-existing marker
/// (`v1` / `v3`) written before this type existed. It records that the
/// migration *ran* in some earlier version. What it cannot record is **which
/// tools existed then** — so the caller declares that, per flag, via
/// ``init(url:legacyCoverage:)``.
///
/// This is load-bearing. Reading a legacy marker as "covered everything"
/// promotes "covered the tools this migration knew about" into "covered the
/// unbounded future", which reintroduces the permanent-skip bug this type
/// exists to close — for every tool added afterwards. Reading it as "covered
/// nothing" is the opposite error: every migration re-runs on upgrade.
/// Declaring the historical set is the only answer that is neither.
///
/// The set differs per migration and must not be shared: a migration that only
/// ever touched claude did not cover codex, and claiming otherwise costs codex
/// its migration forever.
public struct MigrationFlag {
    public enum Coverage: Equatable {
        /// No flag file — the migration has never run.
        case absent
        /// The tool ids this migration has covered. A legacy marker resolves to
        /// the `legacyCoverage` declared at construction, so there is no third
        /// "covers everything" case to reason about — the wildcard is
        /// unrepresentable rather than handled.
        case ids(Set<String>)
    }

    private static let formatVersion = "v2"

    public let url: URL

    /// The tool ids a legacy (version-only) marker in this file should be taken
    /// to have covered — the set this migration genuinely handled in the
    /// version that wrote the marker.
    public let legacyCoverage: Set<String>

    public init(url: URL, legacyCoverage: Set<String>) {
        self.url = url
        self.legacyCoverage = legacyCoverage
    }

    public func coverage() -> Coverage {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return .absent }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if !lines.isEmpty { lines.removeFirst() }

        let ids = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // No ids after the marker means a legacy file. It resolves to the
        // declared historical set, never to "everything".
        return .ids(ids.isEmpty ? legacyCoverage : Set(ids))
    }

    /// Which of `candidates` this migration has not yet covered.
    public func pending(among candidates: Set<String>) -> Set<String> {
        switch coverage() {
        case .absent:        return candidates
        case .ids(let done): return candidates.subtracting(done)
        }
    }

    /// Adds `ids` to the covered set. Unions rather than replaces, so a
    /// migration that runs for one late-registered tool does not erase the
    /// record of the tools it already handled — including the ones a legacy
    /// marker stands for, which `coverage()` has now resolved into the declared
    /// historical set.
    ///
    /// That resolution is what makes the union correct here. While a legacy
    /// marker read as a separate "covers everything" case, this method had
    /// nothing to union against and silently replaced it, so the first
    /// late-registered tool cost every built-in its coverage and re-ran them
    /// all. The two bugs were the same one seen from either end.
    public func markCovered(_ ids: Set<String>) throws {
        var all = ids
        if case .ids(let existing) = coverage() {
            all.formUnion(existing)
        }
        let body = ([Self.formatVersion] + all.sorted()).joined(separator: "\n") + "\n"
        try Data(body.utf8).write(to: url, options: .atomic)
    }
}
