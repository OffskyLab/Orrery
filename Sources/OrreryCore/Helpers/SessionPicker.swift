import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct SessionPicker {
    /// Display an interactive session picker.
    /// Throws `ValidationError` in non-TTY environments.
    /// Returns the selected (sessionName, entry) tuple.
    public static func pick(
        mappings: [(name: String, entry: SessionMappingEntry)],
        store: EnvironmentStore,
        cwd: String
    ) throws -> (name: String, entry: SessionMappingEntry) {
        guard isatty(STDIN_FILENO) != 0 else {
            throw ValidationError(L10n.Delegate.sessionPickerRequiresTTY)
        }
        guard !mappings.isEmpty else {
            throw ValidationError(L10n.Delegate.noManagedSessions)
        }

        let rows = mappings.map { name, entry in
            let toolBadge = Tool(rawValue: entry.tool)?.rawValue ?? entry.tool
            let summary = entry.summary.map { String($0.prefix(50)) } ?? "(no summary)"
            let time = String(entry.lastUsed.prefix(10))
            return "\(name) \u{00B7} \(toolBadge) \u{00B7} \(summary) \u{00B7} \(time)"
        }

        let selector = SingleSelect(title: L10n.Delegate.sessionPickerTitle, options: rows)
        let index = selector.run()

        return mappings[index]
    }
}
