import Foundation
import AIToolKit

/// Reading who a codex config directory is logged in as.
///
/// Everything lives in one file, `auth.json`, in one of two shapes:
///
/// - **API key.** `auth_mode` is `"api"` and the key sits alongside it. There is
///   no email, because there is no user — the account is the key.
/// - **OAuth.** A `tokens.id_token` JWT carries the email as a claim, and the
///   plan under OpenAI's own namespaced claim.
///
/// The host supplies the directory. Nothing here derives a home: the seam that
/// redirects one (`ORRERY_USER_HOME`) does not cross a process boundary, so a
/// plugin that worked out its own `~` would read the developer's real config
/// during an isolated run.
enum CodexIdentity {

    /// - Returns: `nil` when the directory holds no usable login. A file that is
    ///   absent, unreadable or in a shape this build does not recognise all mean
    ///   the same thing to a caller — there is no identity to show — and none of
    ///   them is worth failing a whole listing over.
    static func read(in configDir: URL) -> LoginIdentity? {
        let url = configDir.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // An API key is a real login with no user attached. Reporting it as
        // absent would hide an account that works; inventing an email for it
        // would be worse still.
        if (object["auth_mode"] as? String) == "api" {
            return LoginIdentity(email: nil, plan: "api key")
        }

        guard let tokens = object["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              let claims = jwtPayload(idToken)
        else { return nil }

        let email = claims["email"] as? String
        let plan = (claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String
        // Both nil means the token parsed but said nothing about who it belongs
        // to, which is not an identity worth reporting.
        return email == nil && plan == nil ? nil : LoginIdentity(email: email, plan: plan)
    }

    /// The payload segment of a JWT, decoded.
    ///
    /// Base64url, and unpadded as JWTs are — `Data(base64Encoded:)` rejects a
    /// string whose length is not a multiple of four, so the padding has to be
    /// put back. The signature is neither checked nor needed: this reads a file
    /// codex wrote locally for its own use, and a caller who can tamper with it
    /// can equally tamper with anything else in the directory.
    private static func jwtPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
