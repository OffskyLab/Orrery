import Foundation

public enum ClaudeUsageError: Error, LocalizedError {
    case noAccessToken
    case httpError(status: Int, body: String?)
    case transport(any Error)
    case decode(any Error)

    public var errorDescription: String? {
        switch self {
        case .noAccessToken:
            return "Claude is not logged in for this environment (no OAuth access token in keychain)."
        case .httpError(let status, let body):
            let suffix = body.map { " — \($0)" } ?? ""
            return "Claude usage endpoint returned HTTP \(status)\(suffix)"
        case .transport(let err):
            return "Could not reach api.anthropic.com: \(err.localizedDescription)"
        case .decode(let err):
            return "Could not parse usage response: \(err.localizedDescription)"
        }
    }
}

/// Fetches usage / quota info from Anthropic's `/api/oauth/usage` endpoint.
///
/// This is the same endpoint `claude-code` calls (we located it by reverse
/// engineering its bundled binary). It requires an OAuth bearer token from
/// the Claude Keychain entry for the target config dir.
public enum ClaudeUsageFetcher {
    /// `nil` configDir = origin (system `~/.claude`).
    public static func fetch(configDir: String?) throws -> UsageQuota {
        guard let token = try ClaudeKeychain.validAccessToken(for: configDir) else {
            throw ClaudeUsageError.noAccessToken
        }
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        var request = URLRequest(url: url, timeoutInterval: 5.0)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("orrery/\(OrreryVersion.current)", forHTTPHeaderField: "User-Agent")
        // OAuth-authenticated endpoints reject requests without this beta header
        // ("OAuth authentication is currently not supported"). Discovered while
        // reverse-engineering claude-code's bootstrap call.
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try syncDataTask(with: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ClaudeUsageError.httpError(status: http.statusCode, body: body)
        }

        do {
            return try JSONDecoder().decode(UsageQuota.self, from: data)
        } catch {
            throw ClaudeUsageError.decode(error)
        }
    }

    /// `URLSession.dataTask` doesn't have a sync wrapper on Linux/older macOS,
    /// and `async let` would force every caller into async. Drive it via a
    /// dispatch group instead — used only here, where the whole CLI run is
    /// single-shot anyway.
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
