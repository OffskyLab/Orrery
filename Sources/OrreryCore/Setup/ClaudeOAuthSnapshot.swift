import Foundation

/// Pool-side snapshot of `.claude.json`'s `oauthAccount` block.
///
/// Claude's login state is split across two stores: the keychain (token, plan)
/// and `.claude.json` (oauthAccount.emailAddress and other identity fields).
/// `KeychainCredentialAdapter` only synchronises the keychain side, so without
/// this snapshot the two stores drift on every `orrery use` — the keychain
/// gets the right credential but `.claude.json`'s `oauthAccount` keeps the
/// previously-active identity, producing displays like "gradyzhuo + team"
/// where the email and plan are from different accounts.
///
/// The snapshot lives at `<poolDir>/oauthAccount.json`. `prepareMaterialize`
/// writes it into the active `.claude.json`'s `oauthAccount` key (preserving
/// other top-level keys). `prepareSyncBack` and `AccountLoginFlow.importFrom`
/// capture it from the active / staging `.claude.json`.
public enum ClaudeOAuthSnapshot {
    private static let snapshotFile = "oauthAccount.json"

    public static func snapshotURL(poolDir: URL) -> URL {
        poolDir.appendingPathComponent(snapshotFile)
    }

    /// Read the pool snapshot. Returns nil if missing or unparsable.
    public static func loadSnapshot(poolDir: URL) -> [String: Any]? {
        let url = snapshotURL(poolDir: poolDir)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// Persist the snapshot to the pool dir. Overwrites any existing file.
    @discardableResult
    public static func saveSnapshot(_ snapshot: [String: Any], poolDir: URL) -> Bool {
        let url = snapshotURL(poolDir: poolDir)
        guard let data = try? JSONSerialization.data(
            withJSONObject: snapshot, options: [.sortedKeys, .prettyPrinted])
        else { return false }
        try? FileManager.default.createDirectory(at: poolDir, withIntermediateDirectories: true)
        return ((try? data.write(to: url, options: .atomic)) != nil)
    }

    /// Read the `oauthAccount` block from a `.claude.json` file. Returns nil
    /// if the file is missing or malformed or has no `oauthAccount` key.
    public static func readFromClaudeJSON(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["oauthAccount"] as? [String: Any]
        else { return nil }
        return oauth
    }

    /// Write the snapshot into the `oauthAccount` key of a `.claude.json`
    /// file, preserving every other top-level key. Creates the file if
    /// necessary. Returns true on success.
    @discardableResult
    public static func writeToClaudeJSON(_ snapshot: [String: Any], at url: URL) -> Bool {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        root["oauthAccount"] = snapshot
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
        else { return false }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return ((try? data.write(to: url, options: .atomic)) != nil)
    }

    /// Capture the `oauthAccount` block from the active/staging `.claude.json`
    /// into the pool snapshot. Returns true if a snapshot was written.
    @discardableResult
    public static func captureFromActive(
        activeClaudeJSONURL: URL, poolDir: URL
    ) -> Bool {
        guard let snap = readFromClaudeJSON(at: activeClaudeJSONURL) else {
            return false
        }
        return saveSnapshot(snap, poolDir: poolDir)
    }

    /// Apply the pool snapshot into the active `.claude.json`. If the pool
    /// has no snapshot yet, fall back to deriving a minimal one from the
    /// credential JWT's `email` claim (so legacy pre-snapshot slots still
    /// land in a consistent state after their first materialize). Returns
    /// true if `.claude.json` was written.
    @discardableResult
    public static func applyToActive(
        poolDir: URL,
        activeClaudeJSONURL: URL,
        fallbackCredentialJSON: String? = nil
    ) -> Bool {
        if let snap = loadSnapshot(poolDir: poolDir) {
            return writeToClaudeJSON(snap, at: activeClaudeJSONURL)
        }
        if let json = fallbackCredentialJSON,
           let email = jwtEmail(fromCredentialJSON: json) {
            return writeToClaudeJSON(["emailAddress": email], at: activeClaudeJSONURL)
        }
        return false
    }

    /// Extract `email` from the `claudeAiOauth.accessToken` JWT payload.
    /// Returns nil if the credential is unparsable or the JWT has no email.
    public static func jwtEmail(fromCredentialJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - b64.count % 4) % 4
        b64 += String(repeating: "=", count: pad)
        guard let payloadData = Data(base64Encoded: b64),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { return nil }
        return payload["email"] as? String
    }
}
