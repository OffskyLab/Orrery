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

    /// A built-in tool that owns accounts, standing in for whichever capability
    /// exists when this is next read. What is under test is the reconciliation,
    /// not this particular capability.
    private struct Owning: AIToolAccounts {
        let id = "owning"
        let displayName = "Owning"
        func list() async throws -> [any AIToolKit.Account] { [] }
        func current() async throws -> (any AIToolKit.Account)? { nil }
        func addAccount(id: AccountID, name: String) async throws -> any AIToolKit.Account {
            throw AccountError.noSuchAccount(id)
        }
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
        #expect(ToolCapability.accounts(of: Owning()) != nil)
        #expect(ToolCapability.accounts(of: Plain()) == nil)
        #expect(ToolCapability.identityReporting(of: Plain()) == nil)
    }

    // MARK: remote tools answer from what they advertised

    @Test("a remote tool exposes only the capabilities its plugin advertised")
    func remoteCapabilitiesFollowAdvertisement() async throws {
        let both = try await RemoteAITool.connect(
            transport: plugin(advertising: [
                "tool/list", "tool/current", "tool/setCurrent",
                "tool/addAccount", "tool/deleteAccount", "tool/pin",
                "tool/adoptLogin",
                "tool/listIdentities", "tool/showIdentity",
            ]),
            timeout: .seconds(1))
        #expect(ToolCapability.accounts(of: both) != nil)
        #expect(ToolCapability.identityReporting(of: both) != nil)

        let neither = try await RemoteAITool.connect(
            transport: plugin(advertising: []), timeout: .seconds(1))
        #expect(ToolCapability.accounts(of: neither) == nil,
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
        #expect(ToolCapability.accounts(of: identityOnly) == nil)
    }

    /// All of the account methods or none. A plugin offering some of them would
    /// give the host a pool it can fill and never empty, and the first delete is
    /// a bad place to find that out.
    @Test("an incomplete account surface is not the capability")
    func partialAccountSurfaceIsNotTheCapability() async throws {
        let almost = try await RemoteAITool.connect(
            transport: plugin(advertising: [
                "tool/list", "tool/current", "tool/setCurrent",
                "tool/addAccount", "tool/deleteAccount", "tool/pin",
            ]),   // every one but tool/adoptLogin
            timeout: .seconds(1))

        #expect(ToolCapability.accounts(of: almost) == nil)
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
        #expect(ToolCapability.accounts(of: tool) == nil)
        #expect(ToolCapability.identityReporting(of: tool) == nil)
    }
}
