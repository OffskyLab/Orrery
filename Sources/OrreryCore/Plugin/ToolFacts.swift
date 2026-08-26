import Foundation
import AIToolKit

/// A tool's facts, read from the registry instead of from the enum.
///
/// The enum still exists and still answers — `Tool.defaultConfigDir` is
/// unchanged — because its callers move one at a time. What these add is the
/// other source: for a plugin-provided tool the answer has crossed a process
/// boundary, and for any tool it can be *absent*.
///
/// Absence is the whole reason these return optionals rather than falling back
/// to the enum. A fallback would make the plugin unobservable: `orrery-claude`
/// could be deleted and every path would keep working exactly as before, which
/// is indistinguishable from the plugin never having been consulted. It would
/// also quietly undo the rule that a tool whose plugin failed to load is *not
/// available* — the bootstrap says so out loud, and a silent fallback would
/// contradict it one call site at a time.
///
/// The registry is a parameter with a `.shared` default so tests never touch the
/// shared instance, matching `AIToolRegistration`.
extension Tool {

    /// This tool as the registry describes it, or nil when nothing is registered
    /// under its id — a plugin-provided tool whose plugin did not load.
    public func described(in registry: AIToolRegistry = .shared) -> (any AITool)? {
        registry.tool(id: rawValue)
    }

    /// The system default config directory, built from the registry's answer.
    ///
    /// Resolved against ``userHomeURL()`` rather than the real home, for the same
    /// reason `Tool.defaultConfigDir` is: `ORRERY_USER_HOME` is what keeps an
    /// isolated test from writing into the developer's `~/.claude`.
    public func configDir(in registry: AIToolRegistry = .shared) -> URL? {
        described(in: registry).map {
            userHomeURL().appendingPathComponent($0.configDirectoryName)
        }
    }
}
