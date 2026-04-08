import Testing
import Foundation
@testable import OrbitalCore

@Suite("OrbitalEnvironment")
struct OrbitalEnvironmentTests {

    @Test("round-trips through JSON")
    func jsonRoundTrip() throws {
        let env = OrbitalEnvironment(
            name: "work",
            description: "Work account",
            createdAt: Date(timeIntervalSince1970: 0),
            lastUsed: Date(timeIntervalSince1970: 0),
            tools: [.claude, .codex],
            env: ["ANTHROPIC_API_KEY": "sk-test"]
        )
        let data = try JSONEncoder().encode(env)
        let decoded = try JSONDecoder().decode(OrbitalEnvironment.self, from: data)
        #expect(decoded.name == "work")
        #expect(decoded.tools == [.claude, .codex])
        #expect(decoded.env["ANTHROPIC_API_KEY"] == "sk-test")
    }
}

@Suite("Tool")
struct ToolTests {

    @Test("all tools have correct env var names")
    func envVarNames() {
        #expect(Tool.claude.envVarName == "CLAUDE_CONFIG_DIR")
        #expect(Tool.codex.envVarName == "CODEX_CONFIG_DIR")
        #expect(Tool.gemini.envVarName == "GEMINI_CONFIG_DIR")
    }

    @Test("all tools have correct subdirectory names")
    func subdirectoryNames() {
        #expect(Tool.claude.subdirectory == "claude")
        #expect(Tool.codex.subdirectory == "codex")
        #expect(Tool.gemini.subdirectory == "gemini")
    }

    @Test("Tool initialises from string name")
    func initFromString() {
        #expect(Tool(rawValue: "claude") == .claude)
        #expect(Tool(rawValue: "unknown") == nil)
    }
}
