import Foundation

/// Outcome of one OAuth refresh_token exchange.
enum TokenRefreshOutcome: Sendable {
    case success(accessToken: String, refreshToken: String, expiresIn: TimeInterval)
    case failure(reason: String)
}

/// Injectable seam over the HTTP call that exchanges a Claude Code OAuth
/// refresh token for a new access token. Mirrors `UpdateNoticeFetcher`'s
/// closure-based transport (`Sources/OrreryCore/Update/UpdateNoticeFetcher.swift`)
/// so both are testable without a network.
struct TokenRefreshTransport: Sendable {
    var refresh: @Sendable (_ refreshToken: String) -> TokenRefreshOutcome

    static let live = TokenRefreshTransport(refresh: curlRefresh)
}

extension TokenRefreshTransport {
    /// The fixed, public OAuth client_id every Claude Code install uses —
    /// not a secret, just an application identifier.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// Both endpoints are seen in the wild (reverse-engineered, not
    /// officially documented); try the newer one first and fall back so a
    /// silent endpoint migration doesn't quietly break refresh.
    static let tokenEndpoints: [URL] = [
        URL(string: "https://platform.claude.com/v1/oauth/token")!,
        URL(string: "https://console.anthropic.com/v1/oauth/token")!,
    ]

    static let curlRefresh: @Sendable (String) -> TokenRefreshOutcome = { refreshToken in
        var lastFailure = "no endpoint attempted"
        for endpoint in tokenEndpoints {
            switch post(refreshToken: refreshToken, to: endpoint) {
            case .success(let outcome):
                return outcome
            case .retryNext(let reason):
                lastFailure = reason
                continue
            }
        }
        return .failure(reason: lastFailure)
    }

    private enum AttemptResult {
        case success(TokenRefreshOutcome)
        case retryNext(String)
    }

    private static func post(refreshToken: String, to endpoint: URL) -> AttemptResult {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return .retryNext("failed to encode request body")
        }

        let tmp = FileManager.default.temporaryDirectory
        let bodyFile = tmp.appendingPathComponent("orrery-oauth-refresh-req-\(UUID().uuidString)")
        let respFile = tmp.appendingPathComponent("orrery-oauth-refresh-resp-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: bodyFile)
            try? FileManager.default.removeItem(at: respFile)
        }
        guard (try? bodyData.write(to: bodyFile)) != nil else {
            return .retryNext("failed to write request body")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "curl", "-s", "--max-time", "10",
            "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", "User-Agent: orrery-cli",
            "--data", "@\(bodyFile.path)",
            "-o", respFile.path,
            "-w", "%{http_code}",
            endpoint.absoluteString,
        ]

        let statusPipe = Pipe()
        process.standardOutput = statusPipe
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else {
            return .retryNext("failed to launch curl")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return .retryNext("curl exited with status \(process.terminationStatus)")
        }

        let statusData = statusPipe.fileHandleForReading.readDataToEndOfFile()
        let statusStr = String(data: statusData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let httpStatus = Int(statusStr) else {
            return .retryNext("no HTTP status from curl")
        }

        guard (200...299).contains(httpStatus) else {
            return .retryNext("HTTP \(httpStatus) from \(endpoint.host ?? endpoint.absoluteString)")
        }

        guard let respData = try? Data(contentsOf: respFile),
              let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let newRefreshToken = json["refresh_token"] as? String,
              let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue
        else {
            return .retryNext("malformed refresh response from \(endpoint.host ?? endpoint.absoluteString)")
        }

        // Visible in token-refresh.log — cheap early-warning if Anthropic
        // ever moves the endpoint out from under us (see plan risks).
        FileHandle.standardError.write(
            Data("orrery: token refresh served by \(endpoint.host ?? endpoint.absoluteString)\n".utf8)
        )

        return .success(.success(accessToken: accessToken, refreshToken: newRefreshToken, expiresIn: expiresIn))
    }
}
