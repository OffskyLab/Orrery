import Testing
import Foundation
@testable import OrreryCore

@Suite("Workspace")
struct WorkspaceTests {

    @Test("round-trips through JSON")
    func jsonRoundTrip() throws {
        let env = Workspace(
            name: "work",
            description: "Work account",
            createdAt: Date(timeIntervalSince1970: 0),
            lastUsed: Date(timeIntervalSince1970: 0),
            tools: [.claude, .codex],
            env: ["ANTHROPIC_API_KEY": "sk-test"]
        )
        let data = try JSONEncoder().encode(env)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        #expect(decoded.name == "work")
        #expect(decoded.tools == [.claude, .codex])
        #expect(decoded.env["ANTHROPIC_API_KEY"] == "sk-test")
    }

    @Test("decodes a legacy origin config.json missing id/name as the reserved origin env")
    func decodeLegacyOriginConfig() throws {
        // Old origin/config.json shape: only the 4 OriginConfig fields, no id/name.
        let legacy = """
        {"isolateMemory":true,"isolatedSessionTools":["gemini"],"accounts":{"claude":"ABC"}}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let env = try decoder.decode(Workspace.self, from: legacy)
        #expect(env.id == "origin")
        #expect(env.name == "origin")
        #expect(env.isolateMemory == true)
        #expect(env.isolatedSessionTools == [.gemini])
        #expect(env.account(for: .claude) == "ABC")
    }
}

@Suite("Tool")
struct ToolTests {

    @Test("all tools have correct env var names")
    func envVarNames() {
        #expect(Tool.claude.envVarName == "CLAUDE_CONFIG_DIR")
        #expect(Tool.codex.envVarName == "CODEX_HOME")
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
