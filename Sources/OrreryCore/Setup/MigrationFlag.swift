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
/// ## File format
///
/// A file this type writes begins with an explicit header line, followed by one
/// tool id per line:
///
///     orrery-migration-flag/1
///     claude
///     codex
///
/// Anything whose first line is *not* that header is a pre-existing marker
/// (`v1` / `v2` / `v3`) written before this type existed.
///
/// The header is deliberately not a bare version token. An earlier format used
/// `v2`, which collided with the legacy markers in the worst possible way: a
/// file holding only `v2\n` was simultaneously "a legacy marker" and "the new
/// format recording zero ids". That made total failure indistinguishable from
/// total success — the emptier the recorded set, the more coverage it claimed
/// on the next read. A header that cannot be mistaken for a version removes the
/// ambiguity rather than documenting it.
///
/// ## The four states
///
/// - ``Coverage/absent`` — no file. The migration has never run.
/// - ``Coverage/legacy`` — a pre-per-tool marker. It records that the migration
///   *ran*, but not which tools existed then, so it resolves to the
///   `legacyCoverage` declared at construction.
/// - ``Coverage/ids(_:)`` — an explicit set, which **may be empty**. Empty means
///   "this migration has recorded nothing as done", not "everything is done".
/// - ``Coverage/unreadable`` — the file exists but cannot be read or decoded.
///   Distinct from `absent` on purpose: treating an unreadable flag as
///   never-run re-runs the migration, and for the credential migration that
///   means taking another full backup and touching credentials on every single
///   startup while the flag stays unwritable.
///
/// ## Legacy coverage is per-migration
///
/// Reading a legacy marker as "covered everything" promotes "covered the tools
/// this migration knew about" into "covered the unbounded future", which
/// reintroduces the permanent-skip bug this type exists to close. Reading it as
/// "covered nothing" re-runs every migration on upgrade. Declaring the
/// historical set is the only answer that is neither — and it differs per
/// migration: one that only ever touched claude did not cover codex, and
/// claiming otherwise costs codex its migration forever.
public struct MigrationFlag {
    public enum Coverage: Equatable {
        /// No flag file — the migration has never run.
        case absent
        /// A pre-per-tool marker, resolving to the declared `legacyCoverage`.
        case legacy
        /// An explicit set of covered ids. May be empty.
        case ids(Set<String>)
        /// The file exists but could not be read or decoded.
        case unreadable
    }

    /// Raised when a caller asks what is pending and the flag cannot be read.
    /// Callers must decide — a migration that only adds metadata can warn and
    /// skip, but one that moves credentials must not proceed on a guess.
    public struct Unreadable: Error, CustomStringConvertible {
        public let url: URL
        public var description: String {
            "migration flag at \(url.path) exists but could not be read"
        }
    }

    /// The first line of a file this type writes. Not a bare version token —
    /// see the type's documentation for why that mattered.
    static let formatHeader = "orrery-migration-flag/1"

    public let url: URL

    /// The tool ids a legacy (pre-per-tool) marker in this file should be taken
    /// to have covered — the set this migration genuinely handled in the version
    /// that wrote the marker.
    public let legacyCoverage: Set<String>

    public init(url: URL, legacyCoverage: Set<String>) {
        self.url = url
        self.legacyCoverage = legacyCoverage
    }

    public func coverage() -> Coverage {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }

        // The file exists, so a failure past this point is a real failure, not
        // an absence. Anything else would let a permissions problem read as
        // "never ran".
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return .unreadable }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard let header = lines.first else { return .unreadable }
        guard header == Self.formatHeader else { return .legacy }
        lines.removeFirst()

        // Every remaining non-empty line is a tool id — even one shaped like a
        // version token, since ids are not under this type's control and only
        // line 1 is ever read as a header.
        return .ids(Set(lines.filter { !$0.isEmpty }))
    }

    /// The ids this flag records as covered, or nil when the flag is unreadable.
    private func covered() -> Set<String>? {
        switch coverage() {
        case .absent:        return []
        case .legacy:        return legacyCoverage
        case .ids(let done): return done
        case .unreadable:    return nil
        }
    }

    /// Which of `candidates` this migration has not yet covered.
    ///
    /// Throws when the flag exists but cannot be read. Returning "everything is
    /// pending" there would re-run the migration; returning "nothing" would skip
    /// it forever. Neither is a decision this type can make for its caller.
    public func pending(among candidates: Set<String>) throws -> Set<String> {
        guard let done = covered() else { throw Unreadable(url: url) }
        return candidates.subtracting(done)
    }

    /// Adds `ids` to the covered set, unioning rather than replacing so a
    /// migration that runs for one late-registered tool does not erase the
    /// record of the tools it already handled.
    ///
    /// A call with nothing to add and no existing file writes **no file at
    /// all**. Writing a header with zero ids would be correct under this
    /// format, but leaving the flag absent is equally correct and strictly
    /// safer: it cannot be misread, and the next run recomputes the same
    /// pending set from scratch.
    ///
    /// Throws on an unreadable flag rather than overwriting it — the existing
    /// contents may be the only record of what has already been done.
    public func markCovered(_ ids: Set<String>) throws {
        let existing = coverage()
        if case .unreadable = existing { throw Unreadable(url: url) }

        var all = ids
        switch existing {
        case .legacy:        all.formUnion(legacyCoverage)
        case .ids(let done): all.formUnion(done)
        case .absent:        break
        case .unreadable:    break  // unreachable, thrown above
        }

        if all.isEmpty, case .absent = existing { return }

        let body = ([Self.formatHeader] + all.sorted()).joined(separator: "\n") + "\n"
        try Data(body.utf8).write(to: url, options: .atomic)
    }
}
