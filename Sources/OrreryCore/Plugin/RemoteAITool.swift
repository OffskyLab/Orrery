import Foundation
import AIToolKit

public enum RemoteAIToolError: Error, Equatable, Sendable {
    /// The plugin speaks a protocol major this host does not know. Refused
    /// with an explanation rather than run degraded on a guess.
    case unsupportedProtocol(String)
    /// `initialize` did not yield a usable protocolVersion.
    case handshakeFailed(String)
    /// `tool/describe` returned an error, or could not be called.
    case describeFailed(String)
    /// `tool/describe` answered, but the answer was not a tool description.
    case describeMalformed(String)
}

/// A tool that lives in another process.
///
/// It conforms to `AITool` like any local description, which is the whole
/// point: `AIToolRegistry` stays `[String: any AITool]`, and no call site can
/// tell a remote tool from a compiled-in one.
///
/// The eight fields are fetched once at connect time and cached. They are
/// facts about a tool, and a tool does not change its config directory name
/// while orrery is running — so paying a round trip per property read would
/// buy nothing.
public struct RemoteAITool: AITool {
    private let description: ToolDescription
    private let connection: JSONRPCConnection

    public var id: String { description.id }
    public var displayName: String { description.displayName }
    public var configDirectoryName: String { description.configDirectoryName }
    public var configDirEnvVar: String? { description.configDirEnvVar }
    public var authLoginCommand: [String]? { description.authLoginCommand }
    public var installCommand: [String]? { description.installCommand }
    public var sessionSubdirectories: [String] { description.sessionSubdirectories }
    public var ansiColor: String { description.ansiColor }

    /// Whether the plugin behind this description still answers.
    ///
    /// The eight fields are cached at connect time, so they keep answering long
    /// after the process they came from is gone — which means comparing them
    /// cannot tell a live plugin from a dead one. This asks the process
    /// something, and only a live one can reply.
    ///
    /// It exists because a defect of exactly that shape shipped: every plugin
    /// that connected successfully was killed the instant it registered, and
    /// the registry entry it left behind looked entirely correct.
    public var isConnectionAlive: Bool {
        get async {
            do {
                _ = try await connection.call("tool/describe", nil)
                return true
            } catch {
                return false
            }
        }
    }

    private init(description: ToolDescription, connection: JSONRPCConnection) {
        self.description = description
        self.connection = connection
    }

    /// Handshakes, checks the protocol major, and caches the description.
    public static func connect(
        transport: any Transport,
        timeout: Duration
    ) async throws -> any AITool {
        let connection = JSONRPCConnection(transport: transport, timeout: timeout)

        // The peer is a third-party process orrery does not control: a
        // handshake timeout, a malformed response, an id mismatch and the
        // rest of JSONRPCConnection's failure modes are all real outcomes of
        // talking to one, not internal bugs, so they are wrapped the same
        // way the describe step below is.
        let hello: RPCValue
        do {
            hello = try await connection.call("initialize", nil)
        } catch {
            throw RemoteAIToolError.handshakeFailed(String(describing: error))
        }
        guard case .object(let obj) = hello,
              case .string(let version)? = obj["protocolVersion"]
        else { throw RemoteAIToolError.handshakeFailed("initialize returned no protocolVersion") }

        // What the plugin says it can do, taken at its word. A plugin that
        // advertises an operation and then refuses it is a broken plugin; a
        // host that called an unadvertised one would be the broken party.
        var capabilities: Set<String> = []
        if case .object(let caps)? = obj["capabilities"] {
            capabilities = Set(caps.compactMap { $0.value == .bool(true) ? $0.key : nil })
        }

        let theirMajor = version.split(separator: ".").first.map(String.init) ?? version
        let ourMajor = PluginServer.protocolVersion.split(separator: ".").first
            .map(String.init) ?? PluginServer.protocolVersion
        guard theirMajor == ourMajor else {
            throw RemoteAIToolError.unsupportedProtocol(version)
        }

        // Same reasoning as the initialize call above: wrapped so a caller
        // managing user credentials can say "plugin X sent a description I
        // could not read" instead of leaking a decoder's key-not-found from
        // deep inside Foundation.
        let described: RPCValue
        do {
            described = try await connection.call("tool/describe", nil)
        } catch {
            throw RemoteAIToolError.describeFailed(String(describing: error))
        }

        let description: ToolDescription
        do {
            let data = try JSONEncoder().encode(described)
            description = try JSONDecoder().decode(ToolDescription.self, from: data)
        } catch {
            throw RemoteAIToolError.describeMalformed(String(describing: error))
        }

        let base = RemoteAITool(description: description, connection: connection)

        // Which *type* comes back is the load-bearing part. A conformance is
        // static, so one remote type would conform to `AIToolStateTransfer` for
        // every plugin — including the ones that cannot perform the operations —
        // and `tool is any AIToolStateTransfer` is the entire mechanism by which
        // a host is meant to see that absence. Returning the type that matches
        // what the plugin advertised keeps that check honest.
        if capabilities.contains("tool/copyLoginState"),
           capabilities.contains("tool/copyNonLoginSettings") {
            return RemoteTransferringAITool(base: base, connection: connection)
        }
        return base
    }
}

/// A remote tool whose plugin advertised the state-transfer operations.
///
/// Composes ``RemoteAITool`` rather than inheriting from it — a struct cannot —
/// and forwards the eight description fields to it. The duplication is eight
/// one-line forwards, and it buys the property that matters: a describe-only
/// plugin never produces a value that claims it can copy credentials.
public struct RemoteTransferringAITool: AIToolStateTransfer {
    private let base: RemoteAITool
    private let connection: JSONRPCConnection

    init(base: RemoteAITool, connection: JSONRPCConnection) {
        self.base = base
        self.connection = connection
    }

    public var id: String { base.id }
    public var displayName: String { base.displayName }
    public var configDirectoryName: String { base.configDirectoryName }
    public var configDirEnvVar: String? { base.configDirEnvVar }
    public var authLoginCommand: [String]? { base.authLoginCommand }
    public var installCommand: [String]? { base.installCommand }
    public var sessionSubdirectories: [String] { base.sessionSubdirectories }
    public var ansiColor: String { base.ansiColor }

    public var isConnectionAlive: Bool {
        get async { await base.isConnectionAlive }
    }

    public func copyLoginState(from sourceDir: URL?, to targetDir: URL) async throws -> Bool {
        // `.null` rather than omitting the key: nil is the instruction "your own
        // default location", which is a different thing from an absent argument.
        let result = try await connection.call("tool/copyLoginState", [
            "sourceDir": sourceDir.map { RPCValue.string($0.path) } ?? .null,
            "targetDir": .string(targetDir.path),
        ])
        // A reply that does not say whether it copied is not a usable answer:
        // guessing either way risks reporting work that never happened.
        guard case .object(let obj) = result, case .bool(let copied)? = obj["copied"] else {
            throw RemoteAIToolError.describeMalformed(
                "tool/copyLoginState returned no 'copied' flag")
        }
        return copied
    }

    public func copyNonLoginSettings(from sourceDir: URL, to targetDir: URL) async throws {
        _ = try await connection.call("tool/copyNonLoginSettings", [
            "sourceDir": .string(sourceDir.path),
            "targetDir": .string(targetDir.path),
        ])
    }
}
