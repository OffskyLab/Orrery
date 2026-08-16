import Foundation

/// Picks which supervised session an `orrery phantom` invocation targets.
///
/// The common case is unambiguous and stays that way: when the command runs
/// inside a supervised claude, `ORRERY_PHANTOM_ID` is inherited from the shim
/// and names the session exactly. Everything below that is for out-of-band
/// invocations, which have to guess from cwd and then ask.
public enum PhantomTargetSelector {

    public struct Candidate: Equatable, Sendable {
        public let id: String
        public let entry: PhantomEntry
    }

    public enum Selection: Equatable, Sendable {
        case selected(id: String, entry: PhantomEntry)
        case ambiguous([Candidate])
        case none
    }

    public static func select(
        entries: [(id: String, entry: PhantomEntry)],
        envPhantomId: String?,
        cwd: String,
        explicit: String?
    ) -> Selection {
        guard !entries.isEmpty else { return .none }

        // An explicit selector is either a registry id or a 1-based index into
        // the candidate list the user was just shown.
        if let explicit {
            if let hit = entries.first(where: { $0.id == explicit }) {
                return .selected(id: hit.id, entry: hit.entry)
            }
            if let n = Int(explicit), n >= 1, n <= entries.count {
                let hit = entries[n - 1]
                return .selected(id: hit.id, entry: hit.entry)
            }
            return .none
        }

        // In-chain: the shim exported this, so it is exact.
        if let envPhantomId, let hit = entries.first(where: { $0.id == envPhantomId }) {
            return .selected(id: hit.id, entry: hit.entry)
        }

        let sameCwd = entries.filter { $0.entry.cwd == cwd }
        if sameCwd.count == 1 {
            return .selected(id: sameCwd[0].id, entry: sameCwd[0].entry)
        }
        if sameCwd.count > 1 {
            return .ambiguous(sameCwd.map { Candidate(id: $0.id, entry: $0.entry) })
        }
        return .ambiguous(entries.map { Candidate(id: $0.id, entry: $0.entry) })
    }
}
