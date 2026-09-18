import Foundation
import Testing
import AIToolKit
@testable import OrreryCore

/// One way to ask "can this tool do X?", whichever side of the process boundary
/// the answer lives on.
///
/// A built-in tool answers by conforming: the capability is a compile-time fact.
/// A remote tool cannot, because whether its plugin implements an operation is
/// runtime data — the capability set arrives in the `initialize` reply. Swift
/// conformances are static, so a remote type either conforms always (and lies
/// about describe-only plugins) or there is one type per combination of
/// capabilities, which doubles with each one added.
///
/// So `RemoteAITool` carries its capabilities as optionals and these accessors
/// reconcile the two shapes. Call sites ask the same question either way and
/// never learn which kind of tool they hold — which is the property the registry
/// was built for.
@Suite("tool capabilities")
struct ToolCapabilityTests {

    private struct Plain: AITool {
        let id = "plain"
        let displayName = "Plain"
    }

    private struct Transferring: AIToolStateTransfer {
        let id = "transferring"
        let displayName = "Transferring"
        func copyLoginState(from sourceDir: URL?, to targetDir: URL) async throws -> Bool { true }
        func copyNonLoginSettings(from sourceDir: URL, to targetDir: URL) async throws {}
    }

    private func describeResult() -> RPCValue {
        .object([
            "id": .string("claude"), "displayName": .string("Claude"),
            "configDirectoryName": .string(".claude"), "configDirEnvVar": .null,
            "authLoginCommand": .null, "installCommand": .null,
            "sessionSubdirectories": .array([]), "ansiColor": .string(""),
        ])
    }

    /// A plugin advertising exactly the capabilities named.
    private func plugin(advertising caps: [String]) -> InMemoryTransport {
        InMemoryTransport { line in
            guard let req = try? JSONDecoder().decode(JSONRPCRequest.self, from: line)
            else { return nil }
            switch req.method {
            case "initialize":
                var caps_: [String: RPCValue] = ["tool/describe": .bool(true)]
                for c in caps { caps_[c] = .bool(true) }
                return try? JSONEncoder().encode(JSONRPCResponse(
                    id: req.id,
                    result: .object(["protocolVersion": .string(PluginServer.protocolVersion),
                                     "capabilities": .object(caps_)]),
                    error: nil))
            case "tool/describe":
                return try? JSONEncoder().encode(
                    JSONRPCResponse(id: req.id, result: describeResult(), error: nil))
            case "tool/showIdentity":
                return try? JSONEncoder().encode(JSONRPCResponse(
                    id: req.id,
                    result: .object(["identity": .object(["email": .string("a@b.c"), "plan": .null])]),
                    error: nil))
            default:
                return try? JSONEncoder().encode(JSONRPCResponse(
                    id: req.id, result: .object([:]), error: nil))
            }
        }
    }

    // MARK: built-ins answer by conforming

    @Test("a built-in tool's capability is found through the same accessor")
    func builtInConformanceIsFound() {
        #expect(ToolCapability.stateTransfer(of: Transferring()) != nil)
        #expect(ToolCapability.stateTransfer(of: Plain()) == nil)
        #expect(ToolCapability.identityReporting(of: Plain()) == nil)
    }

    // MARK: remote tools answer from what they advertised

    @Test("a remote tool exposes only the capabilities its plugin advertised")
    func remoteCapabilitiesFollowAdvertisement() async throws {
        let both = try await RemoteAITool.connect(
            transport: plugin(advertising: [
                "tool/copyLoginState", "tool/copyNonLoginSettings",
                "tool/listIdentities", "tool/showIdentity",
            ]),
            timeout: .seconds(1))
        #expect(ToolCapability.stateTransfer(of: both) != nil)
        #expect(ToolCapability.identityReporting(of: both) != nil)

        let neither = try await RemoteAITool.connect(
            transport: plugin(advertising: []), timeout: .seconds(1))
        #expect(ToolCapability.stateTransfer(of: neither) == nil,
                "conforming anyway would make the check a lie for describe-only plugins")
        #expect(ToolCapability.identityReporting(of: neither) == nil)
    }

    /// The reason for optionals rather than a type per combination: this is the
    /// case that would need a fourth type, and the next capability an eighth.
    @Test("a plugin with one capability and not the other is representable")
    func partialCapabilityIsRepresentable() async throws {
        let identityOnly = try await RemoteAITool.connect(
            transport: plugin(advertising: ["tool/listIdentities", "tool/showIdentity"]),
            timeout: .seconds(1))

        #expect(ToolCapability.identityReporting(of: identityOnly) != nil)
        #expect(ToolCapability.stateTransfer(of: identityOnly) == nil)
    }

    @Test("a capability reached through the accessor really talks to the plugin")
    func capabilityForwards() async throws {
        let tool = try await RemoteAITool.connect(
            transport: plugin(advertising: ["tool/listIdentities", "tool/showIdentity"]),
            timeout: .seconds(1))
        let reporter = try #require(ToolCapability.identityReporting(of: tool))

        let identity = try await reporter.showIdentity(in: URL(fileURLWithPath: "/tmp/x"))

        // Not just a non-nil accessor: the value came back over the wire.
        #expect(identity?.email == "a@b.c")
        #expect(identity?.plan == nil)
    }

    /// Both halves advertise `tool/describe`, so a tool is never *only*
    /// describable by accident — absence of the others has to be deliberate.
    @Test("describe alone grants no operational capability")
    func describeIsNotACapability() async throws {
        let tool = try await RemoteAITool.connect(
            transport: plugin(advertising: []), timeout: .seconds(1))

        #expect(tool.id == "claude", "it still describes itself")
        #expect(ToolCapability.stateTransfer(of: tool) == nil)
        #expect(ToolCapability.identityReporting(of: tool) == nil)
    }
}
