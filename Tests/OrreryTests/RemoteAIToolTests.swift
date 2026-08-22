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
        #expect(tool.ansiColor == "\u{1B}[38;5;173m")
    }

    @Test("a remote tool is interchangeable with a local one through the registry")
    func remoteToolInterchangeableWithLocal() async throws {
        let remote = try await RemoteAITool.connect(
            transport: healthy(), timeout: .milliseconds(200))
        let local = Tool.codex.aiTool

        let registry = AIToolRegistry()
        try registry.register(local)
        try registry.register(remote)

        #expect(Set(registry.all.map(\.id)) == Set([local.id, remote.id]))

        // Read every AITool requirement through `any AITool`, for both
        // entries, via the same code path — nothing here knows which one
        // came from a wire.
        for original in [local, remote] {
            let fetched = try #require(registry.tool(id: original.id))
            #expect(fetched.id == original.id)
            #expect(fetched.displayName == original.displayName)
            #expect(fetched.configDirectoryName == original.configDirectoryName)
            #expect(fetched.configDirEnvVar == original.configDirEnvVar)
            #expect(fetched.authLoginCommand == original.authLoginCommand)
            #expect(fetched.installCommand == original.installCommand)
            #expect(fetched.sessionSubdirectories == original.sessionSubdirectories)
            #expect(fetched.ansiColor == original.ansiColor)
        }
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

    /// initialize succeeds, but tool/describe answers with a JSON-RPC error
    /// body instead of a description.
    private func healthyHandshakeButDescribeErrors() -> InMemoryTransport {
        InMemoryTransport { line in
            guard let req = try? JSONDecoder().decode(JSONRPCRequest.self, from: line)
            else { return nil }
            switch req.method {
            case "initialize":
                let result = RPCValue.object([
                    "protocolVersion": .string(PluginServer.protocolVersion),
                    "capabilities": .object(["tool/describe": .bool(true)]),
                ])
                return try? JSONEncoder().encode(
                    JSONRPCResponse(id: req.id, result: result, error: nil))
            case "tool/describe":
                return try? JSONEncoder().encode(JSONRPCResponse(
                    id: req.id, result: nil,
                    error: .init(code: -32000, message: "plugin exploded")))
            default:
                return nil
            }
        }
    }

    @Test("a describe call that errors surfaces as describeFailed, not a foreign RPC error")
    func describeErrorSurfacesAsDescribeFailed() async throws {
        do {
            _ = try await RemoteAITool.connect(
                transport: healthyHandshakeButDescribeErrors(), timeout: .milliseconds(200))
            Issue.record("expected connect() to throw")
        } catch let error as RemoteAIToolError {
            guard case .describeFailed = error else {
                Issue.record("expected .describeFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("expected RemoteAIToolError, got \(type(of: error)): \(error)")
        }
    }

    /// initialize and tool/describe both succeed, but the description is
    /// missing a required field.
    private func healthyHandshakeButDescribeMissingID() -> InMemoryTransport {
        InMemoryTransport { line in
            guard let req = try? JSONDecoder().decode(JSONRPCRequest.self, from: line)
            else { return nil }
            switch req.method {
            case "initialize":
                let result = RPCValue.object([
                    "protocolVersion": .string(PluginServer.protocolVersion),
                    "capabilities": .object(["tool/describe": .bool(true)]),
                ])
                return try? JSONEncoder().encode(
                    JSONRPCResponse(id: req.id, result: result, error: nil))
            case "tool/describe":
                // Missing "id" — every other required field is present.
                let result = RPCValue.object([
                    "displayName": .string("Anthropic Claude"),
                    "configDirectoryName": .string(".claude"),
                    "configDirEnvVar": .string("CLAUDE_CONFIG_DIR"),
                    "authLoginCommand": .null,
                    "installCommand": .array([.string("sh")]),
                    "sessionSubdirectories": .array([.string("projects")]),
                    "ansiColor": .string("\u{1B}[38;5;173m"),
                ])
                return try? JSONEncoder().encode(
                    JSONRPCResponse(id: req.id, result: result, error: nil))
            default:
                return nil
            }
        }
    }

    @Test("a description missing a required field surfaces as describeMalformed, not a foreign decoding error")
    func describeMissingFieldSurfacesAsDescribeMalformed() async throws {
        do {
            _ = try await RemoteAITool.connect(
                transport: healthyHandshakeButDescribeMissingID(), timeout: .milliseconds(200))
            Issue.record("expected connect() to throw")
        } catch let error as RemoteAIToolError {
            guard case .describeMalformed = error else {
                Issue.record("expected .describeMalformed, got \(error)")
                return
            }
        } catch {
            Issue.record("expected RemoteAIToolError, got \(type(of: error)): \(error)")
        }
    }

    /// A plugin that never answers initialize at all — the handshake itself
    /// times out, before tool/describe is ever reached.
    private func hangingOnInitialize() -> InMemoryTransport {
        InMemoryTransport { _ in
            try? await Task.sleep(for: .seconds(30))
            return nil
        }
    }

    @Test("a handshake that times out surfaces as handshakeFailed, not a foreign RPC error")
    func handshakeTimeoutSurfacesAsHandshakeFailed() async throws {
        do {
            _ = try await RemoteAITool.connect(
                transport: hangingOnInitialize(), timeout: .milliseconds(50))
            Issue.record("expected connect() to throw")
        } catch let error as RemoteAIToolError {
            guard case .handshakeFailed = error else {
                Issue.record("expected .handshakeFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("expected RemoteAIToolError, got \(type(of: error)): \(error)")
        }
    }
}
