import Foundation
import Testing
import AIToolKit
@testable import OrreryCore

@Suite("RemoteAITool")
struct RemoteAIToolTests {

    /// A transport that answers initialize and describe like a healthy plugin.
    private func healthy(version: String = PluginServer.protocolVersion) -> InMemoryTransport {
        InMemoryTransport { line in
            guard let req = try? JSONDecoder().decode(JSONRPCRequest.self, from: line)
            else { return nil }
            let result: RPCValue
            switch req.method {
            case "initialize":
                result = .object([
                    "protocolVersion": .string(version),
                    "capabilities": .object(["tool/describe": .bool(true)]),
                ])
            case "tool/describe":
                result = .object([
                    "id": .string("claude"),
                    "displayName": .string("Anthropic Claude"),
                    "configDirectoryName": .string(".claude"),
                    "configDirEnvVar": .string("CLAUDE_CONFIG_DIR"),
                    "authLoginCommand": .null,
                    "installCommand": .array([.string("sh")]),
                    "sessionSubdirectories": .array([.string("projects")]),
                    "ansiColor": .string("\u{1B}[38;5;173m"),
                ])
            default:
                return try? JSONEncoder().encode(JSONRPCResponse(
                    id: req.id, result: nil,
                    error: .init(code: -32601, message: "no")))
            }
            return try? JSONEncoder().encode(
                JSONRPCResponse(id: req.id, result: result, error: nil))
        }
    }

    @Test("a connected remote tool answers every AITool requirement from the wire")
    func remoteToolCarriesAllFields() async throws {
        let tool = try await RemoteAITool.connect(
            transport: healthy(), timeout: .milliseconds(200))
        #expect(tool.id == "claude")
        #expect(tool.displayName == "Anthropic Claude")
        #expect(tool.configDirectoryName == ".claude")
        #expect(tool.configDirEnvVar == "CLAUDE_CONFIG_DIR")
        #expect(tool.authLoginCommand == nil)
        #expect(tool.installCommand == ["sh"])
        #expect(tool.sessionSubdirectories == ["projects"])
    }

    @Test("a remote tool satisfies AITool, so a registry cannot tell it apart")
    func remoteToolRegisters() async throws {
        let tool = try await RemoteAITool.connect(
            transport: healthy(), timeout: .milliseconds(200))
        let registry = AIToolRegistry()
        try registry.register(tool)
        #expect(registry.all.map(\.id) == ["claude"])
        #expect(registry.tool(id: "claude")?.displayName == "Anthropic Claude")
    }

    @Test("an unknown protocol major is refused rather than guessed at")
    func wrongVersionRefused() async throws {
        await #expect(throws: RemoteAIToolError.unsupportedProtocol("99")) {
            _ = try await RemoteAITool.connect(
                transport: healthy(version: "99"), timeout: .milliseconds(200))
        }
    }

    @Test("a plugin that never answers fails to connect instead of hanging")
    func hangingPluginFailsToConnect() async throws {
        let t = InMemoryTransport { _ in
            try? await Task.sleep(for: .seconds(30))
            return nil
        }
        await #expect(throws: (any Error).self) {
            _ = try await RemoteAITool.connect(transport: t, timeout: .milliseconds(50))
        }
    }
}
