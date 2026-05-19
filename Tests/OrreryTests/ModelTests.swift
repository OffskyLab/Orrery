import Testing
import Foundation
@testable import OrreryCore

@Suite("OrreryEnvironment")
struct OrreryEnvironmentTests {

    @Test("round-trips through JSON")
    func jsonRoundTrip() throws {
        let env = OrreryEnvironment(
            name: "work",
            description: "Work account",
            createdAt: Date(timeIntervalSince1970: 0),
            lastUsed: Date(timeIntervalSince1970: 0),
            tools: [.claude, .codex],
            env: ["ANTHROPIC_API_KEY": "sk-test"]
        )
        let data = try JSONEncoder().encode(env)
        let decoded = try JSONDecoder().decode(OrreryEnvironment.self, from: data)
        #expect(decoded.name == "work")
        #expect(decoded.tools == [.claude, .codex])
        #expect(decoded.env["ANTHROPIC_API_KEY"] == "sk-test")
    }

    @Test("OrreryEnvironment.shareUserMemory defaults to true")
    func envShareUserMemoryDefault() {
        let e = OrreryEnvironment(name: "x")
        #expect(e.shareUserMemory == true)
    }

    @Test("OrreryEnvironment legacy JSON decodes shareUserMemory=true")
    func envLegacyDecodeShareUserMemory() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "x",
          "description": "",
          "createdAt": "2026-01-01T00:00:00Z",
          "lastUsed": "2026-01-01T00:00:00Z",
          "tools": [],
          "env": {},
          "isolatedSessionTools": [],
          "isolateMemory": false
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let e = try decoder.decode(OrreryEnvironment.self, from: json)
        #expect(e.shareUserMemory == true)
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

@Suite("OriginConfig")
struct OriginConfigTests {

    @Test("OriginConfig.shareUserMemory defaults to true")
    func originConfigShareUserMemoryDefault() {
        let c = OriginConfig()
        #expect(c.shareUserMemory == true)
    }

    @Test("OriginConfig decodes legacy JSON without shareUserMemory as enabled")
    func originConfigLegacyDecodeShareUserMemory() throws {
        let json = """
        { "isolateMemory": false, "isolatedSessionTools": [] }
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(OriginConfig.self, from: json)
        #expect(c.shareUserMemory == true)
    }
}
