import Testing
@testable import OrbitalCore

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
            ("/Users/gradyzhuo/.orbital/envs/B761FD59-BCCF-4BB0-AAFF-DE3DCABB882B/claude", "e8005789"),
            ("/Users/gradyzhuo/.orbital/envs/1001BA2F-5CE8-4125-A36A-C753B517B8ED/claude", "98f82f2a"),
        ]
        for c in cases {
            #expect(ClaudeKeychain.service(for: c.path) == "Claude Code-credentials-\(c.hash)")
        }
    }
}
