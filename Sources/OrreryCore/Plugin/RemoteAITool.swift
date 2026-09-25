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

    /// Present only when the plugin advertised every method the capability
    /// needs. `nil` is a fact about this plugin, not a missing lookup.
    public let stateTransfer: (any AIToolStateTransfer)?
    public let identityReporting: (any AIToolIdentityReporting)?
    public let accounts: (any AIToolAccounts)?

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

    private init(
        description: ToolDescription,
        connection: JSONRPCConnection,
        stateTransfer: (any AIToolStateTransfer)?,
        identityReporting: (any AIToolIdentityReporting)?,
        accounts: (any AIToolAccounts)?
    ) {
        self.description = description
        self.connection = connection
        self.stateTransfer = stateTransfer
        self.identityReporting = identityReporting
        self.accounts = accounts
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

        // Capabilities are carried, not encoded in the type. A conformance is
        // static while a plugin's capability set is runtime data, so a remote
        // type either conforms always — lying about describe-only plugins — or
        // there is one type per combination. Two capabilities already need four
        // types and the next needs eight, so the combination is a value here and
        // `ToolCapability` reconciles it with the built-ins, which do conform.
        return RemoteAITool(
            description: description,
            connection: connection,
            stateTransfer: capabilities.contains("tool/copyLoginState")
                && capabilities.contains("tool/copyNonLoginSettings")
                ? RemoteStateTransfer(description: description, connection: connection) : nil,
            identityReporting: capabilities.contains("tool/listIdentities")
                && capabilities.contains("tool/showIdentity")
                ? RemoteIdentityReporting(description: description, connection: connection) : nil,
            accounts: RemoteAccounts.requiredMethods.isSubset(of: capabilities)
                ? RemoteAccounts(description: description, connection: connection) : nil)
    }
}

/// The state-transfer half of a remote tool, present only when its plugin
/// advertised both methods.
///
/// It conforms to ``AIToolStateTransfer`` and therefore has to be an `AITool`
/// too, which is why it carries the description: a capability is asked for
/// *about* a tool, and handing back something that cannot say which tool it
/// belongs to would make it unusable anywhere the id matters.
struct RemoteStateTransfer: AIToolStateTransfer {
    let description: ToolDescription
    let connection: JSONRPCConnection

    var id: String { description.id }
    var displayName: String { description.displayName }
    var configDirectoryName: String { description.configDirectoryName }
    var configDirEnvVar: String? { description.configDirEnvVar }
    var authLoginCommand: [String]? { description.authLoginCommand }
    var installCommand: [String]? { description.installCommand }
    var sessionSubdirectories: [String] { description.sessionSubdirectories }
    var ansiColor: String { description.ansiColor }

    func copyLoginState(from sourceDir: URL?, to targetDir: URL) async throws -> Bool {
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

    func copyNonLoginSettings(from sourceDir: URL, to targetDir: URL) async throws {
        _ = try await connection.call("tool/copyNonLoginSettings", [
            "sourceDir": .string(sourceDir.path),
            "targetDir": .string(targetDir.path),
        ])
    }
}

/// The identity-reporting half of a remote tool, present only when its plugin
/// advertised both methods.
struct RemoteIdentityReporting: AIToolIdentityReporting {
    let description: ToolDescription
    let connection: JSONRPCConnection

    var id: String { description.id }
    var displayName: String { description.displayName }
    var configDirectoryName: String { description.configDirectoryName }
    var configDirEnvVar: String? { description.configDirEnvVar }
    var authLoginCommand: [String]? { description.authLoginCommand }
    var installCommand: [String]? { description.installCommand }
    var sessionSubdirectories: [String] { description.sessionSubdirectories }
    var ansiColor: String { description.ansiColor }

    func listIdentities(in configDirs: [URL]) async throws -> [LoginIdentity?] {
        let result = try await connection.call("tool/listIdentities", [
            "configDirs": .array(configDirs.map { .string($0.path) }),
        ])
        guard case .object(let obj) = result,
              case .array(let items)? = obj["identities"]
        else {
            throw RemoteAIToolError.describeMalformed(
                "tool/listIdentities returned no 'identities' array")
        }
        // The count check is the whole point of the array being positional. A
        // plugin that answered a different number of questions leaves every row
        // after the discrepancy paired with the wrong directory, and each of
        // those rows still looks entirely plausible.
        guard items.count == configDirs.count else {
            throw RemoteAIToolError.describeMalformed(
                "tool/listIdentities: asked about \(configDirs.count) directories, got \(items.count) answers")
        }
        return items.map(Self.decode)
    }

    func showIdentity(in configDir: URL) async throws -> LoginIdentity? {
        let result = try await connection.call("tool/showIdentity", [
            "configDir": .string(configDir.path),
        ])
        guard case .object(let obj) = result, let identity = obj["identity"] else {
            throw RemoteAIToolError.describeMalformed(
                "tool/showIdentity returned no 'identity' key")
        }
        return Self.decode(identity)
    }

    /// `.null` is "no login in that directory" — an answer, not a malformed
    /// reply — so it decodes to nil rather than throwing.
    private static func decode(_ value: RPCValue) -> LoginIdentity? {
        guard case .object(let fields) = value else { return nil }
        func string(_ key: String) -> String? {
            if case .string(let s)? = fields[key] { return s }
            return nil
        }
        return LoginIdentity(email: string("email"), plan: string("plan"))
    }
}

/// One way to ask what a tool can do, whichever side of the boundary answers.
///
/// A built-in tool answers by conforming; a remote one answers from the
/// capability set its plugin advertised at `initialize`. Call sites go through
/// here so they never have to know which kind they hold.
public enum ToolCapability {

    public static func stateTransfer(of tool: any AITool) -> (any AIToolStateTransfer)? {
        if let direct = tool as? any AIToolStateTransfer { return direct }
        return (tool as? RemoteAITool)?.stateTransfer
    }

    public static func identityReporting(of tool: any AITool) -> (any AIToolIdentityReporting)? {
        if let direct = tool as? any AIToolIdentityReporting { return direct }
        return (tool as? RemoteAITool)?.identityReporting
    }

    public static func accounts(of tool: any AITool) -> (any AIToolAccounts)? {
        if let direct = tool as? any AIToolAccounts { return direct }
        return (tool as? RemoteAITool)?.accounts
    }
}
