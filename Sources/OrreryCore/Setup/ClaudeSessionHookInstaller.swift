import Foundation

/// Records the session id claude itself reports, instead of guessing.
///
/// Without this, the session id is inferred by scanning the project's session
/// files for the newest mtime — which answers "who wrote most recently", not
/// "what is *this* claude working on". With two claude sessions open on one
/// project, that guess can resume the switch into the wrong conversation.
///
/// `SessionStart` also fires for `resume`, `clear` and `compact`, so the
/// registry keeps up when the user changes conversations mid-session.
///
/// `SessionEnd` is installed too, but nothing depends on it: phantom ends
/// claude with SIGTERM and whether the hook fires in that case is unverified.
/// Credential capture therefore stays on the shell side, and a missed
/// `SessionEnd` only means the entry is pruned slightly later by the liveness
/// check.
public enum ClaudeSessionHookInstaller {
    public static func install(command: String, settingsURL: URL) {
        let hookList: JSONValue = .array([
            .object([
                "hooks": .array([
                    .object([
                        "type": .string("command"),
                        "command": .string(command),
                    ]),
                ]),
            ]),
        ])

        let patch: JSONValue = .object([
            "hooks": .object([
                "SessionStart": hookList,
                "SessionEnd": hookList,
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
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(target) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }
}

/// The hook's payload handler, separated from the executable so it is testable.
public enum ClaudeSessionHook {
    public static func apply(payload: Data, phantomId: String?, registry: PhantomRegistry) {
        guard let phantomId,
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let sessionId = obj["session_id"] as? String,
              !sessionId.isEmpty,
              var entry = registry.read(id: phantomId)
        else { return }

        entry.sessionId = sessionId
        entry.sessionIdSource = .hook
        entry.updatedAt = Date().timeIntervalSince1970
        try? registry.write(entry, id: phantomId)
    }
}
