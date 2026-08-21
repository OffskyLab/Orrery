# RPC Plugin Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move claude's eight description fields out of orrery's binary and behind a JSON-RPC pipe to a separate `orrery-claude` process, so a third party can add a tool without forking orrery.

**Architecture:** AIToolKit gains a transport-agnostic JSON-RPC layer and a `serve()` entry point for plugin authors. orrery gains `RemoteAITool`, a forwarding proxy that *conforms to `AITool`* — so `AIToolRegistry` stays `[String: any AITool]` and no call site can tell local from remote. codex and gemini stay on the existing `BuiltInAITool` bridge.

**Tech Stack:** Swift 6.0, SwiftPM, swift-testing, `Synchronization.Mutex`, `Foundation.Process`

**Spec:** `docs/superpowers/specs/2026-08-21-rpc-plugin-boundary-design.md`

## Global Constraints

- Swift 6.0; `platforms: [.macOS(.v15)]`.
- **AIToolKit must have zero dependencies and no reference to orrery** beyond explanatory doc-comment prose — no import, no type.
- **AIToolKit must be strictly Swift 6 concurrent with no escape hatches.** `@unchecked Sendable`, `@preconcurrency`, `nonisolated(unsafe)` are banned outright. Verify with `swift build --package-path <literal path> -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` after `rm -rf` of its `.build`.
- Tests use **swift-testing** (`import Testing`, `@Suite`, `@Test`, `#expect`) — **never XCTest**.
- Commit messages use `[FEAT]`/`[FIX]`/`[DOCS]` prefixes and carry **no `Co-Authored-By` trailer**.
- `Tool` stays alive and authoritative this phase. Do not delete it or make it conform to `AITool`.
- **Timeouts must be injectable.** No hardcoded call timeout anywhere; tests use milliseconds.
- **Most tests must not spawn a process.** `InMemoryTransport` carries the bulk of the suite.
- **stdout belongs to the protocol.** Diagnostics go to stderr; an unparseable line is skipped, never fatal.

## Sandbox note for the AIToolKit repo

AIToolKit lives at `/Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit`, outside the orrery worktree. Every git and swift command targeting it **must use a literal absolute path** — `git -C /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit …`, `swift test --package-path /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit`. A `cd` into a computed path, or `git -C <variable>`, is refused by the sandbox.

## File Structure

**AIToolKit — new**

| File | Responsibility |
|---|---|
| `Sources/AIToolKit/RPC/JSONRPCMessage.swift` | Request/response/error wire types and their line framing |
| `Sources/AIToolKit/RPC/Transport.swift` | `Transport` protocol + `InMemoryTransport` |
| `Sources/AIToolKit/RPC/StdioTransport.swift` | Spawned-child transport |
| `Sources/AIToolKit/RPC/JSONRPCConnection.swift` | Client: `call`, injectable timeout, error mapping |
| `Sources/AIToolKit/RPC/ToolDescription.swift` | Codable DTO carrying the eight fields |
| `Sources/AIToolKit/RPC/PluginServer.swift` | `serve()` — the plugin author's entry point |
| `Sources/AIToolKitTestPlugin/main.swift` | Fake plugin with selectable misbehaviour |

**orrery — new**

| File | Responsibility |
|---|---|
| `Sources/OrreryCore/Plugin/RemoteAITool.swift` | The forwarding proxy |
| `Sources/OrreryCore/Plugin/PluginDiscovery.swift` | Locate a tool plugin binary |
| `Sources/orrery-claude/main.swift` | claude's real plugin |

**orrery — modified**

| File | Change |
|---|---|
| `Package.swift` | New `orrery-claude` executable target; test target deps |
| `Sources/OrreryCore/Setup/AIToolRegistration.swift` | Register remote tools alongside built-ins |
| `Sources/OrreryCore/Models/Tool.swift` | Remove claude's fact properties (Task 10) |

---

### Task 1: JSON-RPC wire types

**Files:**
- Create: `/Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit/Sources/AIToolKit/RPC/JSONRPCMessage.swift`
- Test: `/Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit/Tests/AIToolKitTests/JSONRPCMessageTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `JSONRPCRequest(id:method:params:)`, `JSONRPCResponse`, `JSONRPCErrorBody(code:message:)`, `JSONRPCError.methodNotFound`, `RPCParams`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import AIToolKit

@Suite("JSONRPCMessage")
struct JSONRPCMessageTests {

    @Test("a request encodes with jsonrpc 2.0 and its id")
    func requestEncodes() throws {
        let req = JSONRPCRequest(id: 7, method: "tool/describe", params: nil)
        let data = try JSONEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["jsonrpc"] as? String == "2.0")
        #expect(obj["id"] as? Int == 7)
        #expect(obj["method"] as? String == "tool/describe")
    }

    @Test("a result response decodes and carries its id")
    func resultDecodes() throws {
        let line = #"{"jsonrpc":"2.0","id":7,"result":{"id":"claude"}}"#
        let res = try JSONDecoder().decode(JSONRPCResponse.self, from: Data(line.utf8))
        #expect(res.id == 7)
        #expect(res.error == nil)
        #expect(res.result != nil)
    }

    @Test("an error response decodes its code and message")
    func errorDecodes() throws {
        let line = #"{"jsonrpc":"2.0","id":7,"error":{"code":-32601,"message":"Method not found: x"}}"#
        let res = try JSONDecoder().decode(JSONRPCResponse.self, from: Data(line.utf8))
        #expect(res.error?.code == -32601)
        #expect(res.error?.message == "Method not found: x")
        #expect(res.result == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit --filter JSONRPCMessage`
Expected: FAIL — `cannot find 'JSONRPCRequest' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// A JSON value as it crosses the wire.
///
/// The protocol has to carry arbitrary params and results without this package
/// knowing their shapes, and `Any` is not `Sendable`. This closed enum is the
/// smallest thing that is both.
public enum RPCValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([RPCValue])
    case object([String: RPCValue])
    case null

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([RPCValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: RPCValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "unrepresentable JSON value")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v):   try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null:          try c.encodeNil()
        }
    }
}

public typealias RPCParams = [String: RPCValue]

public struct JSONRPCRequest: Codable, Sendable {
    public let jsonrpc: String
    public let id: Int
    public let method: String
    public let params: RPCParams?

    public init(id: Int, method: String, params: RPCParams?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCErrorBody: Codable, Sendable, Equatable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public struct JSONRPCResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: Int
    public let result: RPCValue?
    public let error: JSONRPCErrorBody?

    public init(id: Int, result: RPCValue?, error: JSONRPCErrorBody?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }
}

/// Errors the client raises, as distinct from errors a plugin reports.
public enum JSONRPCError: Error, Equatable, Sendable {
    /// The plugin answered `-32601`. Treated as "capability absent", not failure.
    case methodNotFound(String)
    /// The plugin reported an application error.
    case remote(JSONRPCErrorBody)
    /// No reply within the injected timeout.
    case timedOut(method: String)
    /// The pipe closed while a call was in flight.
    case connectionClosed
    /// A reply arrived that was not a JSON-RPC response.
    case malformedResponse

    public static let methodNotFoundCode = -32601
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit --filter JSONRPCMessage`
Expected: PASS, 3 tests

- [ ] **Step 5: Commit**

```bash
git -C /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit add Sources/AIToolKit/RPC/JSONRPCMessage.swift Tests/AIToolKitTests/JSONRPCMessageTests.swift
git -C /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit commit -m "[FEAT] JSON-RPC wire types

RPCValue exists because the protocol carries params and results whose shapes
this package does not know, and Any is not Sendable. A closed enum is the
smallest thing that is both."
```

---

### Task 2: Transport protocol and InMemoryTransport

**Files:**
- Create: `/Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit/Sources/AIToolKit/RPC/Transport.swift`
- Test: `/Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit/Tests/AIToolKitTests/TransportTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1
- Produces: `protocol Transport: Sendable { func send(_ line: Data) async throws; func receiveLine() async throws -> Data? }`, `InMemoryTransport(handler:)`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import AIToolKit

@Suite("Transport")
struct TransportTests {

    @Test("in-memory transport hands each sent line to the handler and returns its reply")
    func inMemoryRoundTrips() async throws {
        let t = InMemoryTransport { line in
            let text = String(decoding: line, as: UTF8.self)
            return Data("echo:\(text)".utf8)
        }
        try await t.send(Data("hello".utf8))
        let got = try await t.receiveLine()
        #expect(String(decoding: got!, as: UTF8.self) == "echo:hello")
    }

    @Test("a handler returning nil closes the stream")
    func nilHandlerCloses() async throws {
        let t = InMemoryTransport { _ in nil }
        try await t.send(Data("hello".utf8))
        let got = try await t.receiveLine()
        #expect(got == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit --filter Transport`
Expected: FAIL — `cannot find 'InMemoryTransport' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import Synchronization

/// One line in, one line out. Everything above this is transport-agnostic,
/// which is what lets a spawned child today become a socket tomorrow without
/// the protocol changing — and, just as usefully, lets almost every test run
/// without spawning anything.
public protocol Transport: Sendable {
    func send(_ line: Data) async throws
    /// The next line, or nil once the peer is gone.
    func receiveLine() async throws -> Data?
}

/// A transport with no process behind it: the handler *is* the peer.
///
/// A handler may take as long as it likes, which is how timeout behaviour is
/// tested without waiting on a real hung process.
public final class InMemoryTransport: Transport {
    public typealias Handler = @Sendable (Data) async -> Data?

    private let handler: Handler
    private let pending = Mutex<[Data?]>([])

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func send(_ line: Data) async throws {
        let reply = await handler(line)
        pending.withLock { $0.append(reply) }
    }

    public func receiveLine() async throws -> Data? {
        pending.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit --filter Transport`
Expected: PASS, 2 tests

- [ ] **Step 5: Commit**

```bash
git -C /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit add Sources/AIToolKit/RPC/Transport.swift Tests/AIToolKitTests/TransportTests.swift
git -C /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit commit -m "[FEAT] Transport, and an in-memory one

The abstraction earns its keep twice: it is what lets a spawned child become a
socket later without touching the protocol, and what lets almost every test
run without spawning anything."
```

---

### Task 3: JSONRPCConnection with an injectable timeout

**Files:**
- Create: `/Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit/Sources/AIToolKit/RPC/JSONRPCConnection.swift`
- Test: `/Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit/Tests/AIToolKitTests/JSONRPCConnectionTests.swift`

**Interfaces:**
- Consumes: `JSONRPCRequest`, `JSONRPCResponse`, `JSONRPCError`, `RPCValue`, `RPCParams` (Task 1); `Transport`, `InMemoryTransport` (Task 2)
- Produces: `actor JSONRPCConnection { init(transport:timeout:); func call(_ method: String, _ params: RPCParams?) async throws -> RPCValue }`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import AIToolKit

@Suite("JSONRPCConnection")
struct JSONRPCConnectionTests {

    /// Replies to any request with a fixed result object.
    private func echoing(result: RPCValue) -> InMemoryTransport {
        InMemoryTransport { line in
            guard let req = try? JSONDecoder().decode(JSONRPCRequest.self, from: line)
            else { return nil }
            let res = JSONRPCResponse(id: req.id, result: result, error: nil)
            return try? JSONEncoder().encode(res)
        }
    }

    @Test("a call returns the plugin's result")
    func callReturnsResult() async throws {
        let conn = JSONRPCConnection(
            transport: echoing(result: .object(["id": .string("claude")])),
            timeout: .milliseconds(200))
        let got = try await conn.call("tool/describe", nil)
        #expect(got == .object(["id": .string("claude")]))
    }

    @Test("-32601 surfaces as methodNotFound, not a generic failure")
    func methodNotFoundIsDistinct() async throws {
        let t = InMemoryTransport { line in
            let req = try! JSONDecoder().decode(JSONRPCRequest.self, from: line)
            let res = JSONRPCResponse(
                id: req.id, result: nil,
                error: .init(code: -32601, message: "Method not found: \(req.method)"))
            return try? JSONEncoder().encode(res)
        }
        let conn = JSONRPCConnection(transport: t, timeout: .milliseconds(200))
        await #expect(throws: JSONRPCError.methodNotFound("tool/nope")) {
            try await conn.call("tool/nope", nil)
        }
    }

    @Test("a handler that never answers trips the injected timeout")
    func timeoutFires() async throws {
        let t = InMemoryTransport { _ in
            try? await Task.sleep(for: .seconds(30))
            return nil
        }
        let conn = JSONRPCConnection(transport: t, timeout: .milliseconds(50))
        await #expect(throws: JSONRPCError.timedOut(method: "tool/describe")) {
            try await conn.call("tool/describe", nil)
        }
    }

    @Test("a non-JSON line is a malformed response, not a crash")
    func garbageIsHandled() async throws {
        let t = InMemoryTransport { _ in Data("not json at all".utf8) }
        let conn = JSONRPCConnection(transport: t, timeout: .milliseconds(200))
        await #expect(throws: JSONRPCError.malformedResponse) {
            try await conn.call("tool/describe", nil)
        }
    }

    @Test("a closed pipe is reported as closed")
    func closedPipe() async throws {
        let t = InMemoryTransport { _ in nil }
        let conn = JSONRPCConnection(transport: t, timeout: .milliseconds(200))
        await #expect(throws: JSONRPCError.connectionClosed) {
            try await conn.call("tool/describe", nil)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit --filter JSONRPCConnection`
Expected: FAIL — `cannot find 'JSONRPCConnection' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// A JSON-RPC client over any `Transport`.
///
/// An actor rather than a locked class because request ids and in-flight state
/// are mutable and cross task boundaries; the compiler verifies the isolation
/// instead of taking a promise.
public actor JSONRPCConnection {
    private let transport: any Transport
    private let timeout: Duration
    private var nextID = 1

    /// - Parameter timeout: never defaulted at the call site. A hardcoded
    ///   timeout produces a test suite nobody runs.
    public init(transport: any Transport, timeout: Duration) {
        self.transport = transport
        self.timeout = timeout
    }

    public func call(_ method: String, _ params: RPCParams?) async throws -> RPCValue {
        let id = nextID
        nextID += 1
        let request = JSONRPCRequest(id: id, method: method, params: params)
        let line = try JSONEncoder().encode(request)

        let reply = try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { [transport] in
                try await transport.send(line)
                return try await transport.receiveLine()
            }
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                throw JSONRPCError.timedOut(method: method)
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }

        guard let reply else { throw JSONRPCError.connectionClosed }

        guard let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: reply)
        else { throw JSONRPCError.malformedResponse }

        if let error = response.error {
            if error.code == JSONRPCError.methodNotFoundCode {
                throw JSONRPCError.methodNotFound(method)
            }
            throw JSONRPCError.remote(error)
        }

        guard let result = response.result else { throw JSONRPCError.malformedResponse }
        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit --filter JSONRPCConnection`
Expected: PASS, 5 tests

- [ ] **Step 5: Verify strict concurrency still holds**

Run:
```bash
rm -rf /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit/.build
swift build --package-path /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```
Expected: `Build complete!`, zero warnings

- [ ] **Step 6: Commit**

```bash
git -C /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit add Sources/AIToolKit/RPC/JSONRPCConnection.swift Tests/AIToolKitTests/JSONRPCConnectionTests.swift
git -C /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit commit -m "[FEAT] JSON-RPC client with an injectable timeout

An actor rather than a locked class: request ids and in-flight state are
mutable and cross task boundaries, so the compiler should verify the isolation
rather than accept a promise.

The timeout has no default. A hardcoded one produces a suite nobody runs, and
-32601 is mapped to its own case because 'the plugin does not implement this'
is a capability answer, not a failure."
```

---

### Task 4: ToolDescription DTO

**Files:**
- Create: `/Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit/Sources/AIToolKit/RPC/ToolDescription.swift`
- Test: `/Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit/Tests/AIToolKitTests/ToolDescriptionTests.swift`

**Interfaces:**
- Consumes: `AITool` (already shipped)
- Produces: `ToolDescription` (Codable struct with the eight fields), `ToolDescription.init(_ tool: any AITool)`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import AIToolKit

@Suite("ToolDescription")
struct ToolDescriptionTests {

    private struct Sample: AITool {
        let id = "claude"
        let displayName = "Claude Code"
        let configDirectoryName = ".claude"
        let configDirEnvVar: String? = "CLAUDE_CONFIG_DIR"
        let authLoginCommand: [String]? = nil
        let installCommand: [String]? = ["sh", "-c", "install.sh"]
        let sessionSubdirectories = ["projects"]
        let ansiColor = "\u{1B}[38;5;173m"
    }

    @Test("a description captures every field of the tool it was built from")
    func capturesAllFields() {
        let d = ToolDescription(Sample())
        #expect(d.id == "claude")
        #expect(d.displayName == "Claude Code")
        #expect(d.configDirectoryName == ".claude")
        #expect(d.configDirEnvVar == "CLAUDE_CONFIG_DIR")
        #expect(d.authLoginCommand == nil)
        #expect(d.installCommand == ["sh", "-c", "install.sh"])
        #expect(d.sessionSubdirectories == ["projects"])
        #expect(d.ansiColor == "\u{1B}[38;5;173m")
    }

    @Test("a description survives a round trip through JSON")
    func roundTrips() throws {
        let original = ToolDescription(Sample())
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(ToolDescription.self, from: data)
        #expect(back == original)
    }

    @Test("a nil optional stays nil across the wire, rather than becoming empty")
    func nilSurvives() throws {
        let data = try JSONEncoder().encode(ToolDescription(Sample()))
        let back = try JSONDecoder().decode(ToolDescription.self, from: data)
        #expect(back.authLoginCommand == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit --filter ToolDescription`
Expected: FAIL — `cannot find 'ToolDescription' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// A tool's eight fields, in the shape they take on the wire.
///
/// This is the concrete `Codable` type ``AITool`` deliberately is not: a
/// protocol cannot be `Decodable`, because decoding has to know what to build.
/// Serialization belongs here so the interface stays clean enough for a
/// forwarding proxy to conform to it.
public struct ToolDescription: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let configDirectoryName: String
    public let configDirEnvVar: String?
    public let authLoginCommand: [String]?
    public let installCommand: [String]?
    public let sessionSubdirectories: [String]
    public let ansiColor: String

    public init(
        id: String,
        displayName: String,
        configDirectoryName: String,
        configDirEnvVar: String?,
        authLoginCommand: [String]?,
        installCommand: [String]?,
        sessionSubdirectories: [String],
        ansiColor: String
    ) {
        self.id = id
        self.displayName = displayName
        self.configDirectoryName = configDirectoryName
        self.configDirEnvVar = configDirEnvVar
        self.authLoginCommand = authLoginCommand
        self.installCommand = installCommand
        self.sessionSubdirectories = sessionSubdirectories
        self.ansiColor = ansiColor
    }

    public init(_ tool: any AITool) {
        self.init(
            id: tool.id,
            displayName: tool.displayName,
            configDirectoryName: tool.configDirectoryName,
            configDirEnvVar: tool.configDirEnvVar,
            authLoginCommand: tool.authLoginCommand,
            installCommand: tool.installCommand,
            sessionSubdirectories: tool.sessionSubdirectories,
            ansiColor: tool.ansiColor)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit --filter ToolDescription`
Expected: PASS, 3 tests

- [ ] **Step 5: Commit**

```bash
git -C /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit add Sources/AIToolKit/RPC/ToolDescription.swift Tests/AIToolKitTests/ToolDescriptionTests.swift
git -C /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit commit -m "[FEAT] ToolDescription, the wire shape of a tool

The concrete Codable type AITool deliberately is not. A protocol cannot be
Decodable because decoding must know what to build, so serialization lives
here and the interface stays clean enough for a proxy to conform to it."
```

---

### Task 5: PluginServer — the plugin author's entry point

**Files:**
- Create: `/Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit/Sources/AIToolKit/RPC/PluginServer.swift`
- Test: `/Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit/Tests/AIToolKitTests/PluginServerTests.swift`

**Interfaces:**
- Consumes: `JSONRPCRequest`, `JSONRPCResponse`, `RPCValue`, `ToolDescription`
- Produces: `PluginServer.handle(line:tool:) -> Data?`, `PluginServer.protocolVersion` (`"1"`), `PluginServer.serve(tool:)`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import AIToolKit

@Suite("PluginServer")
struct PluginServerTests {

    private struct Sample: AITool {
        let id = "sample"
        let displayName = "Sample"
    }

    private func reply(to method: String) throws -> JSONRPCResponse? {
        let req = JSONRPCRequest(id: 1, method: method, params: nil)
        let line = try JSONEncoder().encode(req)
        guard let out = PluginServer.handle(line: line, tool: Sample()) else { return nil }
        return try JSONDecoder().decode(JSONRPCResponse.self, from: out)
    }

    @Test("initialize reports the protocol version and its capabilities")
    func initializeAnswers() throws {
        let res = try #require(try reply(to: "initialize"))
        guard case .object(let obj) = try #require(res.result) else {
            Issue.record("expected an object result"); return
        }
        #expect(obj["protocolVersion"] == .string(PluginServer.protocolVersion))
        guard case .object(let caps) = try #require(obj["capabilities"]) else {
            Issue.record("expected capabilities to be an object"); return
        }
        #expect(caps["tool/describe"] == .bool(true))
    }

    @Test("tool/describe answers with the tool's own fields")
    func describeAnswers() throws {
        let res = try #require(try reply(to: "tool/describe"))
        guard case .object(let obj) = try #require(res.result) else {
            Issue.record("expected an object result"); return
        }
        #expect(obj["id"] == .string("sample"))
        #expect(obj["displayName"] == .string("Sample"))
        #expect(obj["configDirectoryName"] == .string(".sample"))
    }

    @Test("an unimplemented method answers -32601 rather than going silent")
    func unknownMethodIsMethodNotFound() throws {
        let res = try #require(try reply(to: "tool/nope"))
        #expect(res.error?.code == -32601)
    }

    @Test("an unparseable line produces no reply and does not throw")
    func garbageLineIsIgnored() {
        #expect(PluginServer.handle(line: Data("not json".utf8), tool: Sample()) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit --filter PluginServer`
Expected: FAIL — `cannot find 'PluginServer' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// The plugin side of the protocol. A plugin author implements ``AITool`` and
/// calls ``serve(tool:)``; the JSON-RPC loop is this package's problem.
public enum PluginServer {

    /// Bumped only on a breaking change. A host that does not recognise the
    /// major refuses the plugin with an explanation rather than guessing.
    public static let protocolVersion = "1"

    /// Answers one request line. Returns nil when the line is not a request
    /// worth answering — an unparseable line is skipped, never fatal, because
    /// stdout carries the protocol and a stray write must not end the session.
    public static func handle(line: Data, tool: any AITool) -> Data? {
        guard let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: line)
        else { return nil }

        let response: JSONRPCResponse
        switch request.method {
        case "initialize":
            response = JSONRPCResponse(id: request.id, result: .object([
                "protocolVersion": .string(protocolVersion),
                "capabilities": .object(["tool/describe": .bool(true)]),
            ]), error: nil)

        case "tool/describe":
            let d = ToolDescription(tool)
            response = JSONRPCResponse(id: request.id, result: .object([
                "id": .string(d.id),
                "displayName": .string(d.displayName),
                "configDirectoryName": .string(d.configDirectoryName),
                "configDirEnvVar": d.configDirEnvVar.map(RPCValue.string) ?? .null,
                "authLoginCommand": d.authLoginCommand.map { .array($0.map(RPCValue.string)) } ?? .null,
                "installCommand": d.installCommand.map { .array($0.map(RPCValue.string)) } ?? .null,
                "sessionSubdirectories": .array(d.sessionSubdirectories.map(RPCValue.string)),
                "ansiColor": .string(d.ansiColor),
            ]), error: nil)

        default:
            response = JSONRPCResponse(
                id: request.id, result: nil,
                error: .init(code: JSONRPCError.methodNotFoundCode,
                             message: "Method not found: \(request.method)"))
        }

        return try? JSONEncoder().encode(response)
    }

    /// Reads requests from stdin and writes replies to stdout until stdin closes.
    ///
    /// Anything a plugin wants to say to a human goes to stderr: stdout belongs
    /// to the protocol, and a stray `print` there desynchronises the stream.
    public static func serve(tool: any AITool) {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard let out = handle(line: Data(line.utf8), tool: tool) else { continue }
            FileHandle.standardOutput.write(out)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit --filter PluginServer`
Expected: PASS, 4 tests

- [ ] **Step 5: Commit**

```bash
git -C /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit add Sources/AIToolKit/RPC/PluginServer.swift Tests/AIToolKitTests/PluginServerTests.swift
git -C /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit commit -m "[FEAT] PluginServer: implement AITool, call serve()

handle(line:tool:) is separated from serve(tool:) so the protocol logic is
testable without a process. An unparseable line yields no reply rather than an
error: stdout carries the protocol, and a stray write must not end the session."
```

---

### Task 6: StdioTransport and the fake plugin

**Files:**
- Create: `/Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit/Sources/AIToolKit/RPC/StdioTransport.swift`
- Create: `/Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit/Sources/AIToolKitTestPlugin/main.swift`
- Modify: `/Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit/Package.swift`
- Test: `/Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit/Tests/AIToolKitTests/StdioTransportTests.swift`

**Interfaces:**
- Consumes: `Transport` (Task 2), `JSONRPCConnection` (Task 3), `PluginServer` (Task 5)
- Produces: `StdioTransport(executable:arguments:environment:)`, `StdioTransport.terminate()`

- [ ] **Step 1: Add the test-plugin target to Package.swift**

```swift
        .executableTarget(
            name: "AIToolKitTestPlugin",
            dependencies: ["AIToolKit"],
            path: "Sources/AIToolKitTestPlugin"
        ),
```

Add `"AIToolKitTestPlugin"` to the test target's `dependencies` so the binary is built before the tests run.

- [ ] **Step 2: Write the fake plugin**

```swift
import Foundation
import AIToolKit

/// A plugin that can be told to misbehave, so the host's failure handling is
/// tested against real process behaviour instead of mocks.
///
/// Doubles as a conformance suite: a third-party author can point these same
/// tests at their own binary.
struct TestTool: AITool {
    let id = "testtool"
    let displayName = "Test Tool"
}

let behaviour = ProcessInfo.processInfo.environment["AITOOLKIT_TEST_BEHAVIOUR"] ?? "ok"

switch behaviour {
case "hang":
    // Accept the request, never answer. The host's timeout must fire.
    while readLine() != nil { Thread.sleep(forTimeInterval: 3600) }

case "garbage":
    while readLine() != nil {
        FileHandle.standardOutput.write(Data("this is not json\n".utf8))
    }

case "noisy":
    // A stray debug print on stdout, then a valid reply. The host must skip
    // the first line rather than treat the stream as broken.
    while let line = readLine(strippingNewline: true) {
        FileHandle.standardOutput.write(Data("debug: got a request\n".utf8))
        if let out = PluginServer.handle(line: Data(line.utf8), tool: TestTool()) {
            FileHandle.standardOutput.write(out)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

case "partial":
    while readLine() != nil {
        FileHandle.standardOutput.write(Data(#"{"jsonrpc":"2.0","id":1,"resu"#.utf8))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

case "wrong-version":
    while let line = readLine(strippingNewline: true) {
        guard let req = try? JSONDecoder().decode(
            JSONRPCRequest.self, from: Data(line.utf8)) else { continue }
        let res = JSONRPCResponse(id: req.id, result: .object([
            "protocolVersion": .string("99"),
            "capabilities": .object([:]),
        ]), error: nil)
        if let out = try? JSONEncoder().encode(res) {
            FileHandle.standardOutput.write(out)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

case "crash-after-initialize":
    var seen = false
    while let line = readLine(strippingNewline: true) {
        if seen { exit(1) }
        if let out = PluginServer.handle(line: Data(line.utf8), tool: TestTool()) {
            FileHandle.standardOutput.write(out)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        seen = true
    }

default:
    PluginServer.serve(tool: TestTool())
}
```

- [ ] **Step 3: Write the failing test**

```swift
import Foundation
import Testing
@testable import AIToolKit

@Suite("StdioTransport")
struct StdioTransportTests {

    /// The test plugin binary, beside the test bundle in the build directory.
    private static var pluginURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("AIToolKitTestPlugin")
    }

    private func connection(behaviour: String, timeout: Duration) -> JSONRPCConnection {
        let t = StdioTransport(
            executable: Self.pluginURL,
            arguments: [],
            environment: ["AITOOLKIT_TEST_BEHAVIOUR": behaviour])
        return JSONRPCConnection(transport: t, timeout: timeout)
    }

    @Test("a real child process answers tool/describe over a real pipe")
    func realPipeWorks() async throws {
        let conn = connection(behaviour: "ok", timeout: .seconds(5))
        let result = try await conn.call("tool/describe", nil)
        guard case .object(let obj) = result else {
            Issue.record("expected an object result"); return
        }
        #expect(obj["id"] == .string("testtool"))
    }

    @Test("a stray debug line on stdout is skipped, not fatal")
    func noisyPluginStillWorks() async throws {
        let conn = connection(behaviour: "noisy", timeout: .seconds(5))
        let result = try await conn.call("tool/describe", nil)
        guard case .object(let obj) = result else {
            Issue.record("expected an object result"); return
        }
        #expect(obj["id"] == .string("testtool"))
    }

    @Test("a plugin that never answers trips the timeout instead of hanging the host")
    func hangingPluginTimesOut() async throws {
        let conn = connection(behaviour: "hang", timeout: .milliseconds(300))
        await #expect(throws: JSONRPCError.timedOut(method: "tool/describe")) {
            try await conn.call("tool/describe", nil)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `swift test --package-path /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit --filter StdioTransport`
Expected: FAIL — `cannot find 'StdioTransport' in scope`

- [ ] **Step 5: Write StdioTransport**

```swift
import Foundation
import Synchronization

/// A transport backed by a spawned child process speaking line-delimited JSON
/// on its stdin and stdout.
///
/// The child's stderr is left attached to the host's, so a plugin's
/// diagnostics reach the operator without polluting the protocol stream.
///
/// Lines that do not parse are skipped by the reader rather than ending the
/// session: a plugin author's stray `print` is a bug in their plugin, not a
/// reason for the host to lose the tool.
public final class StdioTransport: Transport {
    private let process = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private let started = Mutex<Bool>(false)

    public init(executable: URL, arguments: [String], environment: [String: String]) {
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        process.environment = env
        process.standardInput = inPipe
        process.standardOutput = outPipe
        // stderr deliberately inherited, not captured.
    }

    private func startIfNeeded() throws {
        let needsStart = started.withLock { wasStarted -> Bool in
            if wasStarted { return false }
            wasStarted = true
            return true
        }
        if needsStart { try process.run() }
    }

    public func send(_ line: Data) async throws {
        try startIfNeeded()
        inPipe.fileHandleForWriting.write(line)
        inPipe.fileHandleForWriting.write(Data("\n".utf8))
    }

    public func receiveLine() async throws -> Data? {
        let handle = outPipe.fileHandleForReading
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return buffer.isEmpty ? nil : buffer }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                // Skip anything that is not a JSON-RPC response: a plugin's
                // stray stdout write must not desynchronise the stream.
                if (try? JSONDecoder().decode(JSONRPCResponse.self, from: Data(line))) != nil {
                    return Data(line)
                }
            }
        }
    }

    public func terminate() {
        if process.isRunning { process.terminate() }
    }

    deinit { terminate() }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --package-path /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit --filter StdioTransport`
Expected: PASS, 3 tests

- [ ] **Step 7: Verify strict concurrency and the full suite**

Run:
```bash
rm -rf /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit/.build
swift build --package-path /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test --package-path /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit
```
Expected: `Build complete!` with zero warnings; all tests pass

- [ ] **Step 8: Commit**

```bash
git -C /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit add Package.swift Sources/AIToolKit/RPC/StdioTransport.swift Sources/AIToolKitTestPlugin Tests/AIToolKitTests/StdioTransportTests.swift
git -C /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit commit -m "[FEAT] StdioTransport, and a plugin that can be told to misbehave

The reader skips any line that is not a JSON-RPC response, so a plugin
author's stray print is a bug in their plugin rather than a reason for the
host to lose the tool. The child's stderr stays attached to the host's, which
is where diagnostics belong.

The fake plugin doubles as a conformance suite: a third-party author can point
these tests at their own binary."
```

---

### Task 7: Measurement

**Files:**
- Create: `/Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit/Tests/AIToolKitTests/SpawnCostTests.swift`
- Create: `docs/superpowers/notes/2026-08-21-rpc-measurement.md` (in the orrery worktree)

**Interfaces:**
- Consumes: `StdioTransport`, `JSONRPCConnection`
- Produces: a measured number and a named list of orrery's real hot call sites — the exit criterion for the transport decision

- [ ] **Step 1: Write the measurement test**

```swift
import Foundation
import Testing
@testable import AIToolKit

/// Not a pass/fail test — a measurement that prints. The transport decision
/// depends on a number, and a number nobody recorded is a number nobody has.
@Suite("SpawnCost")
struct SpawnCostTests {

    @Test("measure spawn plus initialize plus describe")
    func measureRoundTrip() async throws {
        let plugin = Bundle.main.bundleURL.appendingPathComponent("AIToolKitTestPlugin")
        var samples: [Duration] = []

        for _ in 0..<20 {
            let start = ContinuousClock.now
            let t = StdioTransport(
                executable: plugin, arguments: [],
                environment: ["AITOOLKIT_TEST_BEHAVIOUR": "ok"])
            let conn = JSONRPCConnection(transport: t, timeout: .seconds(5))
            _ = try await conn.call("initialize", nil)
            _ = try await conn.call("tool/describe", nil)
            samples.append(ContinuousClock.now - start)
            t.terminate()
        }

        let sorted = samples.sorted()
        print("SPAWN+INIT+DESCRIBE  median=\(sorted[10])  min=\(sorted[0])  max=\(sorted[19])")
    }
}
```

- [ ] **Step 2: Run it and record the numbers**

Run: `swift test --package-path /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit --filter SpawnCost`
Expected: PASS, with a printed median/min/max line. Copy the real numbers into the notes file in Step 4.

- [ ] **Step 3: Find orrery's real hot call sites**

Do **not** reason about which call sites sound frequent — that already produced a wrong answer once during design (the Claude Code status line was assumed to be the hot RPC client and turns out never to invoke orrery at all).

Run these, from the orrery worktree, and record what they show:

```bash
# every shell-side invocation of the binary
grep -n "orrery-bin" Sources/OrreryCore/Shell/ShellFunctionGenerator.swift

# anything on a timer or a loop
grep -rn "sleep\|while true\|refreshInterval" Sources/OrreryCore/Shell/ShellFunctionGenerator.swift

# who reads tool facts in a loop
grep -rn "Tool.allCases" Sources/ | wc -l
```

- [ ] **Step 4: Write the notes file**

Create `docs/superpowers/notes/2026-08-21-rpc-measurement.md` containing, with the real values from Steps 2 and 3:

```markdown
# RPC transport measurement

**Date:** 2026-08-21

## Spawn + initialize + describe

median: <value>  min: <value>  max: <value>  (20 samples)

## orrery's real high-frequency call sites

| Call site | Frequency | Reads tool facts? |
|---|---|---|
| <site> | <how often> | yes / no |

## Verdict

<Does one spawn per orrery process for facts cost anything a user would
notice? If yes, name the call site that makes it hurt. If no, say so plainly —
a persistent transport stays unbuilt until a measurement demands it.>
```

- [ ] **Step 5: Commit**

```bash
git -C /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit add Tests/AIToolKitTests/SpawnCostTests.swift
git -C /Users/gradyzhuo/Dropbox/Work/OpenSource/AIToolKit commit -m "[FEAT] measure spawn + initialize + describe

Not pass/fail. The transport decision depends on a number, and a number nobody
recorded is a number nobody has."

git add docs/superpowers/notes/2026-08-21-rpc-measurement.md
git commit -m "[DOCS] measured RPC round-trip cost and orrery's real hot call sites

Found by instrumenting rather than by reasoning, because reasoning already
produced a wrong answer during design: the status line was assumed to be the
hot RPC client and never invokes orrery at all."
```

---

### Task 8: RemoteAITool

**Files:**
- Create: `Sources/OrreryCore/Plugin/RemoteAITool.swift`
- Test: `Tests/OrreryTests/RemoteAIToolTests.swift`

**Interfaces:**
- Consumes: `JSONRPCConnection`, `ToolDescription`, `PluginServer.protocolVersion`, `InMemoryTransport` (AIToolKit)
- Produces: `RemoteAITool` (conforms to `AITool`), `RemoteAITool.connect(transport:timeout:) async throws -> RemoteAITool`, `RemoteAIToolError.unsupportedProtocol(String)`

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RemoteAITool`
Expected: FAIL — `cannot find 'RemoteAITool' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import AIToolKit

public enum RemoteAIToolError: Error, Equatable, Sendable {
    /// The plugin speaks a protocol major this host does not know. Refused
    /// with an explanation rather than run degraded on a guess.
    case unsupportedProtocol(String)
    case describeFailed(String)
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

    private init(description: ToolDescription, connection: JSONRPCConnection) {
        self.description = description
        self.connection = connection
    }

    /// Handshakes, checks the protocol major, and caches the description.
    public static func connect(
        transport: any Transport,
        timeout: Duration
    ) async throws -> RemoteAITool {
        let connection = JSONRPCConnection(transport: transport, timeout: timeout)

        let hello = try await connection.call("initialize", nil)
        guard case .object(let obj) = hello,
              case .string(let version)? = obj["protocolVersion"]
        else { throw RemoteAIToolError.describeFailed("initialize returned no protocolVersion") }

        let theirMajor = version.split(separator: ".").first.map(String.init) ?? version
        let ourMajor = PluginServer.protocolVersion.split(separator: ".").first
            .map(String.init) ?? PluginServer.protocolVersion
        guard theirMajor == ourMajor else {
            throw RemoteAIToolError.unsupportedProtocol(version)
        }

        let described = try await connection.call("tool/describe", nil)
        let data = try JSONEncoder().encode(described)
        let description = try JSONDecoder().decode(ToolDescription.self, from: data)

        return RemoteAITool(description: description, connection: connection)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RemoteAITool`
Expected: PASS, 4 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Plugin/RemoteAITool.swift Tests/OrreryTests/RemoteAIToolTests.swift
git commit -m "[FEAT] RemoteAITool: a tool that lives in another process

It conforms to AITool like any local description, which is the point — the
registry stays [String: any AITool] and no call site can tell the difference.

The eight fields are fetched once and cached: they are facts about a tool, and
a tool does not change its config directory name while orrery runs, so a round
trip per property read would buy nothing.

An unknown protocol major is refused with an explanation rather than run
degraded on a guess."
```

---

### Task 9: Plugin discovery and registration

**Files:**
- Create: `Sources/OrreryCore/Plugin/PluginDiscovery.swift`
- Modify: `Sources/OrreryCore/Setup/AIToolRegistration.swift`
- Test: `Tests/OrreryTests/PluginDiscoveryTests.swift`

**Interfaces:**
- Consumes: `RemoteAITool.connect(transport:timeout:)`, `StdioTransport`, `AIToolRegistry`
- Produces: `PluginDiscovery.locate(toolID:environment:) -> URL?`, `AIToolRegistration.registerPlugins(into:timeout:) async`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
import AIToolKit
@testable import OrreryCore

@Suite("PluginDiscovery")
struct PluginDiscoveryTests {

    private func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test("an explicit env var wins over every other location")
    func envVarWins() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plugin-env-\(UUID().uuidString)")
        let bin = dir.appendingPathComponent("orrery-claude")
        try makeExecutable(at: bin)
        defer { try? FileManager.default.removeItem(at: dir) }

        let found = PluginDiscovery.locate(
            toolID: "claude",
            environment: ["ORRERY_CLAUDE_PATH": bin.path])
        #expect(found?.path == bin.path)
    }

    @Test("a missing plugin is absent rather than an error")
    func missingPluginIsNil() {
        let found = PluginDiscovery.locate(
            toolID: "nosuchtool",
            environment: ["ORRERY_HOME": "/nonexistent-\(UUID().uuidString)"])
        #expect(found == nil)
    }

    @Test("an env var pointing at something unexecutable is ignored, not trusted")
    func unexecutablePathIgnored() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plain-\(UUID().uuidString).txt")
        try Data("not a binary".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let found = PluginDiscovery.locate(
            toolID: "claude",
            environment: ["ORRERY_CLAUDE_PATH": file.path,
                          "ORRERY_HOME": "/nonexistent-\(UUID().uuidString)"])
        #expect(found == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PluginDiscovery`
Expected: FAIL — `cannot find 'PluginDiscovery' in scope`

- [ ] **Step 3: Write PluginDiscovery**

```swift
import Foundation

/// Finds a tool plugin binary, in the same order `orrery-sync` is found:
/// an explicit env var, then orrery's own tools directory, then PATH.
///
/// A path that exists but is not executable is ignored rather than trusted —
/// an operator who points the variable at the wrong file should get "no
/// plugin", not a spawn failure deep in a later call.
public enum PluginDiscovery {

    public static func envVarName(toolID: String) -> String {
        "ORRERY_\(toolID.uppercased())_PATH"
    }

    public static func locate(
        toolID: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let fm = FileManager.default

        if let explicit = environment[envVarName(toolID: toolID)],
           fm.isExecutableFile(atPath: explicit) {
            return URL(fileURLWithPath: explicit)
        }

        let home = environment["ORRERY_HOME"]
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".orrery").path
        let local = home + "/tools/orrery-\(toolID)"
        if fm.isExecutableFile(atPath: local) {
            return URL(fileURLWithPath: local)
        }

        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = String(dir) + "/orrery-\(toolID)"
            if fm.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PluginDiscovery`
Expected: PASS, 3 tests

- [ ] **Step 5: Write the registration test**

Append to `Tests/OrreryTests/RegistryCompletenessTests.swift`:

```swift
    @Test("a tool whose plugin is absent is never recorded as covered")
    func absentPluginIsNotRecordedAsCovered() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        // Only claude is present; a hypothetical "cursor" plugin failed to load,
        // so it is not in the registry and must not be claimed as covered.
        let flag = MigrationFlag(url: home.appendingPathComponent(".test-flag"))
        let present: Set<String> = ["claude"]
        let pending = flag.pending(among: present)
        try flag.markCovered(pending)

        #expect(flag.coverage() == .ids(["claude"]))

        // Later, the cursor plugin is fixed and registers.
        let laterPending = flag.pending(among: ["claude", "cursor"])
        #expect(laterPending == ["cursor"],
                "a tool absent at migration time must become pending once it registers")
    }
```

- [ ] **Step 6: Run the registration test**

Run: `swift test --filter RegistryCompleteness`
Expected: PASS — including the new negative assertion

- [ ] **Step 7: Add registerPlugins to AIToolRegistration**

```swift
    /// Registers any tool plugins found on disk, after the built-ins.
    ///
    /// Built-ins go first deliberately: a plugin that claims an id already
    /// taken cannot displace a tool orrery ships.
    ///
    /// A plugin that is missing, hangs, crashes, or speaks an unknown protocol
    /// is skipped with a warning on stderr. One broken plugin must not cost
    /// the host its working tools.
    public static func registerPlugins(
        into registry: AIToolRegistry,
        toolIDs: [String],
        timeout: Duration
    ) async {
        for toolID in toolIDs {
            guard let binary = PluginDiscovery.locate(toolID: toolID) else { continue }
            do {
                let transport = StdioTransport(
                    executable: binary, arguments: [], environment: [:])
                let tool = try await RemoteAITool.connect(
                    transport: transport, timeout: timeout)
                try registry.register(tool)
            } catch {
                FileHandle.standardError.write(Data(
                    "[orrery] tool plugin '\(toolID)' not loaded: \(error)\n".utf8))
            }
        }
    }
```

- [ ] **Step 8: Run the full suite**

Run: `swift test`
Expected: all tests pass, no new warnings

- [ ] **Step 9: Commit**

```bash
git add Sources/OrreryCore/Plugin/PluginDiscovery.swift Sources/OrreryCore/Setup/AIToolRegistration.swift Tests/OrreryTests/PluginDiscoveryTests.swift Tests/OrreryTests/RegistryCompletenessTests.swift
git commit -m "[FEAT] locate tool plugins and register them after the built-ins

Discovery follows orrery-sync's existing order: an explicit env var, then
orrery's tools directory, then PATH. A path that exists but is not executable
is ignored rather than trusted, so a misdirected variable yields 'no plugin'
rather than a spawn failure deep in a later call.

Built-ins register first so a plugin cannot displace a tool orrery ships, and
a plugin that fails to load is skipped with a warning rather than taking the
other tools down with it.

The negative assertion is the important one: a tool absent when one-shot work
runs must not be recorded as covered, and must become pending once it appears."
```

---

### Task 10: orrery-claude, and claude's facts over the wire

**Files:**
- Create: `Sources/orrery-claude/main.swift`
- Modify: `Package.swift`
- Modify: `Sources/OrreryCore/Models/Tool.swift`
- Test: `Tests/OrreryTests/ClaudePluginParityTests.swift`

**Interfaces:**
- Consumes: `PluginServer.serve(tool:)`, `RemoteAITool`, `PluginDiscovery`
- Produces: the `orrery-claude` executable; `Tool.claude` no longer carries its own fact properties

- [ ] **Step 1: Add the executable target to Package.swift**

```swift
        .executableTarget(
            name: "orrery-claude",
            dependencies: [
                .product(name: "AIToolKit", package: "Orrery-AIToolKit"),
            ],
            path: "Sources/orrery-claude"
        ),
```

Add to `products`:

```swift
        .executable(name: "orrery-claude", targets: ["orrery-claude"]),
```

- [ ] **Step 2: Write the plugin**

```swift
import Foundation
import AIToolKit

/// Claude Code, described as a plugin.
///
/// This ships with orrery but is loaded through exactly the mechanism a third
/// party would use — which is what makes it evidence that the mechanism works,
/// rather than a special case that proves nothing.
struct ClaudeTool: AITool {
    let id = "claude"
    let displayName = "\u{1F7E0} Anthropic Claude"
    let configDirectoryName = ".claude"
    let configDirEnvVar: String? = "CLAUDE_CONFIG_DIR"
    let authLoginCommand: [String]? = nil
    let installCommand: [String]? = ["sh", "-c", "curl -fsSL https://claude.ai/install.sh | bash"]
    let sessionSubdirectories = ["projects", "sessions", "session-env"]
    let ansiColor = "\u{1B}[38;5;173m"
}

PluginServer.serve(tool: ClaudeTool())
```

- [ ] **Step 3: Write the parity test**

```swift
import Foundation
import Testing
import AIToolKit
@testable import OrreryCore

/// The plugin must describe claude exactly as the enum did. This is the test
/// that makes the migration safe: if the two ever disagree, this goes red
/// before a user sees a wrong config directory.
@Suite("ClaudePluginParity")
struct ClaudePluginParityTests {

    private var pluginURL: URL {
        // Built beside the test bundle by SwiftPM.
        Bundle.main.bundleURL.appendingPathComponent("orrery-claude")
    }

    @Test("the plugin describes claude exactly as the built-in bridge does")
    func pluginMatchesBridge() async throws {
        let transport = StdioTransport(
            executable: pluginURL, arguments: [], environment: [:])
        let remote = try await RemoteAITool.connect(
            transport: transport, timeout: .seconds(5))
        let local = Tool.claude.aiTool

        #expect(remote.id == local.id)
        #expect(remote.displayName == local.displayName)
        #expect(remote.configDirectoryName == local.configDirectoryName)
        #expect(remote.configDirEnvVar == local.configDirEnvVar)
        #expect(remote.authLoginCommand == local.authLoginCommand)
        #expect(remote.installCommand == local.installCommand)
        #expect(remote.sessionSubdirectories == local.sessionSubdirectories)
        #expect(remote.ansiColor == local.ansiColor)
    }
}
```

- [ ] **Step 4: Run the parity test**

Run: `swift test --filter ClaudePluginParity`
Expected: PASS — proving the plugin and the enum agree on all eight fields

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: all tests pass

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/orrery-claude Tests/OrreryTests/ClaudePluginParityTests.swift
git commit -m "[FEAT] orrery-claude: claude described by a separate process

It ships with orrery but is loaded through exactly the mechanism a third party
would use, which is what makes it evidence the mechanism works rather than a
special case that proves nothing.

The parity test is what makes the migration safe: the plugin and the enum must
agree on all eight fields, so a divergence goes red before a user sees a wrong
config directory."
```

---

## Self-Review

**1. Spec coverage**

| Spec requirement | Task |
|---|---|
| `Transport`, `StdioTransport`, `InMemoryTransport`, `JSONRPCConnection`, `serve()` | 2, 3, 5, 6 |
| Minimal plugin answering `initialize` + `tool/describe` | 6 |
| Measure round trip; instrument to find real hot call sites | 7 |
| `RemoteAITool` proxy, discovery, handshake, version refusal | 8, 9 |
| claude's eight facts over the wire | 10 |
| Timeouts injectable | 3 (no default parameter anywhere) |
| Most tests avoid spawning | 1–5 in-memory; only 6, 7, 10 spawn |
| Absent tool never recorded as covered, with a test | 9 Step 5 |
| stdout protocol-only; unparseable lines skipped | 5 (`handle` returns nil), 6 (`receiveLine` filters) |
| Fake plugin behaviours as a conformance suite | 6 |

**Gap found and closed:** the spec lists a `partial` and `crash-after-initialize` behaviour in the conformance table; Task 6's plugin implements both, but only `ok`, `noisy` and `hang` have tests. This is deliberate — the remaining behaviours exist for the conformance suite a third party runs, and adding host-side tests for them belongs with the behaviour methods that can actually fail mid-call. Noted here so a reviewer does not read it as an oversight.

**2. Placeholder scan:** no "TBD", no "add error handling", every code step carries real code. The one templated file is Task 7's notes document, whose values are filled from the measured output in the same task.

**3. Type consistency:** `RPCParams` = `[String: RPCValue]` used identically in Tasks 1, 3, 5. `JSONRPCConnection.call(_:_:)` takes `(String, RPCParams?)` in Task 3 and is called that way in Tasks 5 and 8. `PluginServer.protocolVersion` is `"1"` in Task 5 and compared against in Task 8. `RemoteAITool.connect(transport:timeout:)` matches between Tasks 8, 9 and 10. `ToolDescription`'s eight field names match the `AITool` requirements exactly.

**Spec defect found and fixed, not worked around:** the spec's Step 3 exit criterion originally read "`Tool`'s claude-specific fact properties are gone." Checking the call sites showed that is not achievable in this scope — 32 callers (`defaultConfigDir`, `subdirectory`) are mechanical, but 11 (`envVarName`) are not: `Tool.gemini.envVarName` returns `"GEMINI_CONFIG_DIR"` while `configDirEnvVar` is `nil`, and PR #52 needs that literal string as a key to *remove* from a child environment. Removing a property whose 11 remaining callers cannot be migrated is a broken step, not a smaller one.

The spec was amended rather than the plan padded. Task 10's exit is now the parity test, which is the thing that actually makes the later removal safe: it pins the plugin's description against the enum's so the two cannot diverge unnoticed while both exist.
