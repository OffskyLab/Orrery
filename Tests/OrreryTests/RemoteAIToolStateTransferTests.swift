import Foundation
import Synchronization
import Testing
import AIToolKit
@testable import OrreryCore

/// Forwarding the two state-transfer operations across the process boundary.
///
/// The load-bearing decision under test is not the forwarding — it is *which
/// type* `connect` hands back. A conformance in Swift is static, so a single
/// remote type would conform to `AIToolStateTransfer` for every plugin, whether
/// or not the plugin can perform the operations. That would make
/// `tool is any AIToolStateTransfer` a lie for describe-only plugins, and that
/// check is the entire mechanism by which a host is supposed to see absence.
/// So `connect` picks the type that matches what the plugin advertised.
@Suite("RemoteAITool state transfer")
struct RemoteAIToolStateTransferTests {

    /// Records what crossed the wire, so a test can assert the arguments the
    /// plugin actually received rather than only the answer it sent back.
    private final class Wire: Sendable {
        let calls = Mutex<[(method: String, params: RPCParams?)]>([])
        func record(_ method: String, _ params: RPCParams?) {
            calls.withLock { $0.append((method, params)) }
        }
        var methods: [String] { calls.withLock { $0.map(\.method) } }
        func params(for method: String) -> RPCParams? {
            calls.withLock { $0.first { $0.method == method }?.params }
        }
    }

    private func describeResult() -> RPCValue {
        .object([
            "id": .string("claude"),
            "displayName": .string("Anthropic Claude"),
            "configDirectoryName": .string(".claude"),
            "configDirEnvVar": .string("CLAUDE_CONFIG_DIR"),
            "authLoginCommand": .null,
            "installCommand": .null,
            "sessionSubdirectories": .array([.string("projects")]),
            "ansiColor": .string(""),
        ])
    }

    /// - Parameters:
    ///   - transfers: whether `initialize` advertises the operations.
    ///   - loginReply: what `tool/copyLoginState` answers.
    private func plugin(
        transfers: Bool,
        wire: Wire = Wire(),
        loginReply: @escaping @Sendable () -> (result: RPCValue?, error: JSONRPCErrorBody?)
            = { (.object(["copied": .bool(true)]), nil) }
    ) -> InMemoryTransport {
        InMemoryTransport { line in
            guard let req = try? JSONDecoder().decode(JSONRPCRequest.self, from: line)
            else { return nil }
            wire.record(req.method, req.params)

            switch req.method {
            case "initialize":
                var caps: [String: RPCValue] = ["tool/describe": .bool(true)]
                if transfers {
                    caps["tool/copyLoginState"] = .bool(true)
                    caps["tool/copyNonLoginSettings"] = .bool(true)
                }
                return try? JSONEncoder().encode(JSONRPCResponse(
                    id: req.id,
                    result: .object(["protocolVersion": .string(PluginServer.protocolVersion),
                                     "capabilities": .object(caps)]),
                    error: nil))
            case "tool/describe":
                return try? JSONEncoder().encode(JSONRPCResponse(
                    id: req.id, result: describeResult(), error: nil))
            case "tool/copyLoginState":
                let (result, error) = loginReply()
                return try? JSONEncoder().encode(
                    JSONRPCResponse(id: req.id, result: result, error: error))
            case "tool/copyNonLoginSettings":
                return try? JSONEncoder().encode(
                    JSONRPCResponse(id: req.id, result: .object([:]), error: nil))
            default:
                return try? JSONEncoder().encode(JSONRPCResponse(
                    id: req.id, result: nil,
                    error: .init(code: JSONRPCError.methodNotFoundCode, message: "no")))
            }
        }
    }

    @Test("a plugin that advertises the operations comes back able to perform them")
    func advertisedCapabilityYieldsAConformer() async throws {
        let tool = try await RemoteAITool.connect(
            transport: plugin(transfers: true), timeout: .seconds(1))

        #expect(tool is any AIToolStateTransfer)
        // Still an ordinary tool in every other respect — the registry holds
        // `any AITool` and must not have to care.
        #expect(tool.id == "claude")
        #expect(tool.configDirectoryName == ".claude")
    }

    @Test("a plugin that does not advertise them comes back unable to perform them")
    func describeOnlyPluginDoesNotConform() async throws {
        let tool = try await RemoteAITool.connect(
            transport: plugin(transfers: false), timeout: .seconds(1))

        #expect(!(tool is any AIToolStateTransfer),
                "conforming anyway would make the host's capability check a lie")
        #expect(tool.id == "claude")
        #expect(tool.sessionSubdirectories == ["projects"])
    }

    @Test("copyLoginState sends the directories the host chose and returns the plugin's answer")
    func copyLoginStateForwards() async throws {
        let wire = Wire()
        let tool = try await RemoteAITool.connect(
            transport: plugin(transfers: true, wire: wire), timeout: .seconds(1))
        let transfer = try #require(tool as? any AIToolStateTransfer)

        let copied = try await transfer.copyLoginState(
            from: URL(fileURLWithPath: "/tmp/src"), to: URL(fileURLWithPath: "/tmp/dst"))

        #expect(copied)
        #expect(wire.methods.contains("tool/copyLoginState"))
        let params = try #require(wire.params(for: "tool/copyLoginState"))
        #expect(params["sourceDir"] == .string("/tmp/src"))
        #expect(params["targetDir"] == .string("/tmp/dst"))
    }

    /// `nil` means "your own default location", which is a different instruction
    /// from any path. It has to survive the crossing as `null` rather than as an
    /// empty string or a missing key.
    @Test("a nil source crosses as null, not as an empty path")
    func nilSourceCrossesAsNull() async throws {
        let wire = Wire()
        let tool = try await RemoteAITool.connect(
            transport: plugin(transfers: true, wire: wire), timeout: .seconds(1))
        let transfer = try #require(tool as? any AIToolStateTransfer)

        _ = try await transfer.copyLoginState(from: nil, to: URL(fileURLWithPath: "/tmp/dst"))

        let params = try #require(wire.params(for: "tool/copyLoginState"))
        #expect(params["sourceDir"] == .null)
    }

    @Test("nothing to copy comes back as false rather than as a failure")
    func nothingToCopyIsAnAnswer() async throws {
        let tool = try await RemoteAITool.connect(
            transport: plugin(transfers: true,
                              loginReply: { (.object(["copied": .bool(false)]), nil) }),
            timeout: .seconds(1))
        let transfer = try #require(tool as? any AIToolStateTransfer)

        let copied = try await transfer.copyLoginState(
            from: URL(fileURLWithPath: "/tmp/src"), to: URL(fileURLWithPath: "/tmp/dst"))

        #expect(!copied)
    }

    /// The distinction the whole design rests on, now across a process
    /// boundary: a plugin that tried and failed must not be readable as a
    /// plugin that had nothing to do.
    @Test("a failed copy throws instead of reading as nothing-to-copy")
    func failureThrows() async throws {
        let tool = try await RemoteAITool.connect(
            transport: plugin(transfers: true, loginReply: {
                (nil, .init(code: JSONRPCError.operationFailedCode, message: "disk full"))
            }),
            timeout: .seconds(1))
        let transfer = try #require(tool as? any AIToolStateTransfer)

        await #expect(throws: (any Error).self) {
            _ = try await transfer.copyLoginState(
                from: URL(fileURLWithPath: "/tmp/src"), to: URL(fileURLWithPath: "/tmp/dst"))
        }
    }

    @Test("copyNonLoginSettings forwards both directories")
    func copySettingsForwards() async throws {
        let wire = Wire()
        let tool = try await RemoteAITool.connect(
            transport: plugin(transfers: true, wire: wire), timeout: .seconds(1))
        let transfer = try #require(tool as? any AIToolStateTransfer)

        try await transfer.copyNonLoginSettings(
            from: URL(fileURLWithPath: "/tmp/a"), to: URL(fileURLWithPath: "/tmp/b"))

        let params = try #require(wire.params(for: "tool/copyNonLoginSettings"))
        #expect(params["sourceDir"] == .string("/tmp/a"))
        #expect(params["targetDir"] == .string("/tmp/b"))
    }
}
