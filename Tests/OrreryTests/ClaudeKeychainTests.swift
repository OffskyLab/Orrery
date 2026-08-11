import Testing
import Foundation
@testable import OrreryCore

@Suite("ClaudeKeychain")
struct ClaudeKeychainTests {
    @Test("service returns no-hash entry when configDir is nil (origin state)")
    func originService() {
        #expect(ClaudeKeychain.service(for: nil) == "Claude Code-credentials")
    }

    @Test("service hashes configDir with SHA256 first-8-hex matching Claude Code")
    func hashedService() {
        // Reference hashes computed independently from Claude Code's key algorithm:
        //   SHA256(path).digest('hex').substring(0, 8)
        let cases: [(path: String, hash: String)] = [
            ("/Users/gradyzhuo/.claude", "cb02b61e"),
            ("/Users/gradyzhuo/.orrery/workspaces/B761FD59-BCCF-4BB0-AAFF-DE3DCABB882B/claude", "32d53f95"),
            ("/Users/gradyzhuo/.orrery/workspaces/1001BA2F-5CE8-4125-A36A-C753B517B8ED/claude", "bc64ad20"),
        ]
        for c in cases {
            #expect(ClaudeKeychain.service(for: c.path) == "Claude Code-credentials-\(c.hash)")
        }
    }
}

#if os(macOS)
@Suite("ClaudeKeychain OAuth credential JSON (pure, no Keychain I/O)")
struct ClaudeKeychainOAuthCredentialTests {
    static let sampleJSON = """
    {
      "claudeAiOauth": {
        "accessToken": "access-1",
        "refreshToken": "refresh-1",
        "expiresAt": 1756162077244,
        "subscriptionType": "pro"
      },
      "mcpOAuth": {
        "figma": { "accessToken": "figma-token" }
      }
    }
    """

    @Test("parseOAuthCredential reads accessToken/refreshToken/expiresAt/subscriptionType")
    func parses() {
        let credential = ClaudeKeychain.parseOAuthCredential(json: Self.sampleJSON)
        #expect(credential?.accessToken == "access-1")
        #expect(credential?.refreshToken == "refresh-1")
        #expect(credential?.subscriptionType == "pro")
        #expect(credential?.expiresAt == Date(timeIntervalSince1970: 1756162077244 / 1000))
    }

    @Test("parseOAuthCredential returns nil when refreshToken is missing")
    func parsesNilWhenIncomplete() {
        let json = """
        {"claudeAiOauth": {"accessToken": "a", "subscriptionType": "pro"}}
        """
        #expect(ClaudeKeychain.parseOAuthCredential(json: json) == nil)
    }

    @Test("applyingOAuthUpdate replaces only the three OAuth fields, preserving sibling keys")
    func updatePreservesSiblingKeys() throws {
        let newExpiry = Date(timeIntervalSince1970: 2_000_000)
        let updatedJSON = try #require(ClaudeKeychain.applyingOAuthUpdate(
            toJSON: Self.sampleJSON,
            accessToken: "access-2",
            refreshToken: "refresh-2",
            expiresAt: newExpiry
        ))

        let data = try #require(updatedJSON.data(using: .utf8))
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let oauth = try #require(obj["claudeAiOauth"] as? [String: Any])

        #expect(oauth["accessToken"] as? String == "access-2")
        #expect(oauth["refreshToken"] as? String == "refresh-2")
        #expect(oauth["subscriptionType"] as? String == "pro")
        #expect((oauth["expiresAt"] as? NSNumber)?.int64Value == 2_000_000_000)

        // Sibling top-level key (e.g. an unrelated MCP OAuth blob) survives untouched.
        let mcpOAuth = try #require(obj["mcpOAuth"] as? [String: Any])
        let figma = try #require(mcpOAuth["figma"] as? [String: Any])
        #expect(figma["accessToken"] as? String == "figma-token")

        // Round-trip: the updated JSON parses back to the new values.
        let reparsed = try #require(ClaudeKeychain.parseOAuthCredential(json: updatedJSON))
        #expect(reparsed.accessToken == "access-2")
        #expect(reparsed.refreshToken == "refresh-2")
        #expect(reparsed.expiresAt == newExpiry)
    }

    @Test("applyingOAuthUpdate returns nil for malformed input")
    func updateNilOnMalformed() {
        #expect(ClaudeKeychain.applyingOAuthUpdate(
            toJSON: "not json",
            accessToken: "a", refreshToken: "b", expiresAt: Date()
        ) == nil)
        #expect(ClaudeKeychain.applyingOAuthUpdate(
            toJSON: "{}",
            accessToken: "a", refreshToken: "b", expiresAt: Date()
        ) == nil)
    }
}
#endif
