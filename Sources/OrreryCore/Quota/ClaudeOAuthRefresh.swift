import Foundation

/// OAuth token refresh for Claude Code credentials.
///
/// Discovered by reverse-engineering `claude-code`'s bundled binary:
///   POST https://platform.claude.com/v1/oauth/token
///   body: { refresh_token, client_id, scope }
///   → { access_token, refresh_token, expires_in, scope, account, organization }
///
/// We only call this when the stored `expiresAt` is in the past. claude-code
/// itself refreshes the same way when running, so writing the new tokens back
/// to the keychain stays compatible with concurrent claude usage.
public enum ClaudeOAuthRefresh {
    /// Public OAuth client ID for the Claude Code CLI. Hard-coded by the
    /// upstream binary; we use the same value because the refresh_token was
    /// issued against it.
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// POST to platform.claude.com to swap a refresh_token for a new
    /// access_token. Returns the parsed response shape.
    public static func refresh(
        refreshToken: String,
        scopes: [String],
        clientID: String = ClaudeOAuthRefresh.clientID
    ) throws -> RefreshedToken {
        let url = URL(string: "https://platform.claude.com/v1/oauth/token")!
        var request = URLRequest(url: url, timeoutInterval: 15.0)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("orrery/\(OrreryVersion.current)", forHTTPHeaderField: "User-Agent")

        let payload: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "scope": scopes.joined(separator: " "),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try syncDataTask(with: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ClaudeUsageError.httpError(status: http.statusCode, body: body)
        }
        do {
            return try JSONDecoder().decode(RefreshedToken.self, from: data)
        } catch {
            throw ClaudeUsageError.decode(error)
        }
    }

    public struct RefreshedToken: Codable, Sendable {
        public let accessToken: String
        public let refreshToken: String
        public let expiresIn: Int
        public let scope: String

        enum CodingKeys: String, CodingKey {
            case accessToken  = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn    = "expires_in"
            case scope
        }
    }

    /// Same dispatch-group dance as ClaudeUsageFetcher — keeps the call sync
    /// for CLI-style usage without forcing async up the stack.
    private static func syncDataTask(with request: URLRequest) throws -> (Data, URLResponse) {
        let group = DispatchGroup()
        var result: (Data, URLResponse)?
        var failure: (any Error)?
        group.enter()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { group.leave() }
            if let error { failure = error; return }
            if let data, let response { result = (data, response) }
        }
        task.resume()
        group.wait()
        if let failure { throw ClaudeUsageError.transport(failure) }
        guard let result else {
            throw ClaudeUsageError.transport(URLError(.badServerResponse))
        }
        return result
    }
}
