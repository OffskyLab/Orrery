import Foundation

/// Unified account-info lookup across tools. Each tool stores login info differently:
/// - Claude: macOS Keychain + `.claude.json`
/// - Codex: `auth.json` (auth_mode + JWT id_token)
/// - Gemini: `oauth_creds.json` (Google OAuth id_token)
public enum ToolAuth {
    public struct AccountInfo: Sendable {
        public let email: String?
        public let plan: String?
        public var isEmpty: Bool { email == nil && plan == nil }
    }

    /// Fast email-only lookup — skips macOS Keychain (for Claude) and subprocess calls.
    /// Useful for deduping during wizards before doing the full `accountInfo` lookup.
    /// Returns nil if no email can be extracted.
    public static func quickEmail(tool: Tool, configDir: URL?) -> String? {
        switch tool {
        case .claude:
            let url: URL
            if let configDir {
                url = configDir.appendingPathComponent(".claude.json")
            } else {
                url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
            }
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauthAccount = obj["oauthAccount"] as? [String: Any]
            else { return nil }
            return oauthAccount["emailAddress"] as? String
        case .codex, .gemini:
            // No Keychain for these — `accountInfo` is already a single file read.
            return accountInfo(tool: tool, configDir: configDir).email
        }
    }

    /// Look up account info for a tool in the given config dir.
    /// Pass `nil` for the tool's default/origin location.
    public static func accountInfo(tool: Tool, configDir: URL?) -> AccountInfo {
        switch tool {
        case .claude:
            #if canImport(CryptoKit)
            return ClaudeKeychain.accountInfo(for: configDir?.path)
            #else
            return AccountInfo(email: nil, plan: nil)
            #endif
        case .codex:
            let dir = configDir ?? tool.defaultConfigDir
            return codexAccountInfo(dir: dir)
        case .gemini:
            let dir = configDir ?? tool.defaultConfigDir
            return geminiAccountInfo(dir: dir)
        }
    }

    // MARK: - Codex

    private static func codexAccountInfo(dir: URL) -> AccountInfo {
        let url = dir.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return AccountInfo(email: nil, plan: nil) }

        if (obj["auth_mode"] as? String) == "api" {
            return AccountInfo(email: nil, plan: "api key")
        }
        guard let tokens = obj["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              let payload = decodeJWTPayload(idToken)
        else { return AccountInfo(email: nil, plan: nil) }

        let email = payload["email"] as? String
        let plan = (payload["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String
        return AccountInfo(email: email, plan: plan)
    }

    // MARK: - Gemini

    private static func geminiAccountInfo(dir: URL) -> AccountInfo {
        // OAuth login: id_token carries the email.
        let oauthURL = dir.appendingPathComponent("oauth_creds.json")
        if let data = try? Data(contentsOf: oauthURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let idToken = obj["id_token"] as? String,
           let payload = decodeJWTPayload(idToken),
           let email = payload["email"] as? String {
            return AccountInfo(email: email, plan: nil)
        }

        // API-key / Vertex auth: the key lives in GEMINI_API_KEY (env var or
        // project `.env`), not in the config dir — only the selected mode is
        // persisted in settings.json. Newer gemini-cli nests it under
        // `security.auth.selectedType`; older versions used top-level `auth`.
        let settingsURL = dir.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let selectedType =
                ((obj["security"] as? [String: Any])?["auth"] as? [String: Any])?["selectedType"] as? String
                ?? (obj["auth"] as? [String: Any])?["selectedType"] as? String
            switch selectedType {
            case "gemini-api-key":
                return AccountInfo(email: nil, plan: "api key")
            case "vertex-ai":
                return AccountInfo(email: nil, plan: "vertex")
            default:
                break
            }
        }

        return AccountInfo(email: nil, plan: nil)
    }

    // MARK: - JWT

    /// Decode a JWT's middle (payload) segment. Returns nil if malformed.
    private static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - b64.count % 4) % 4
        b64 += String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }
}
