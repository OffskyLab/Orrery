import Foundation

#if os(macOS)

/// Patches a claude `settings.json` to add a `Notification` hook for the
/// `auth_success` matcher, firing `command` the instant a login completes.
///
/// Shared by two installers with different `command` strings and target
/// `settings.json` files:
/// - `PrepareClaudeLaunchCommand`, on the account's own directory, pointing
///   at `orrery-claude-hook` (see `ClaudeLoginSync`).
/// - `AccountAddPrepareCommand`, on the staging directory used during
///   `orrery account add --claude`, pointing at `_account-add-finalize`.
///
/// Idempotent (`SettingsJSONPatcher`'s hook-matcher comparator treats an
/// existing entry with the same matcher + command set as already present,
/// so this never duplicates on repeated calls with the same `command`) and
/// additive — every other key already in settings.json, including other
/// hooks, is left untouched. Best-effort: silently no-ops if the file can't
/// be read/written.
public enum ClaudeAuthSuccessHookInstaller {
    public static func install(command: String, settingsURL: URL) {
        let patch: JSONValue = .object([
            "hooks": .object([
                "Notification": .array([
                    .object([
                        "matcher": .string("auth_success"),
                        "hooks": .array([
                            .object([
                                "type": .string("command"),
                                "command": .string(command),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ])

        var target: JSONValue
        if let data = try? Data(contentsOf: settingsURL), !data.isEmpty,
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
            target = decoded
        } else {
            target = .object([:])
        }

        guard (try? SettingsJSONPatcher.apply(patch: patch, to: &target)) != nil else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(target) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }
}

#endif
