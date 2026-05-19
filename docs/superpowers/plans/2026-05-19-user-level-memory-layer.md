# User-level Memory Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a true user-global memory layer to Orrery — a directory at `~/.orrery/user/memory/` accessed by AI tools via MCP (writes) and a SessionStart hook (auto-load), with hook installers for Claude, Codex, and Gemini. Also reorganises the `orrery memory` CLI into `project` / `user` sub-groups (breaking change, v3.0.0).

**Architecture:** New `MemoryStore` value type encapsulates read/write/fragment logic so the same code serves both project- and user-layer storage. A `UserMemoryHookInstaller` protocol with three per-tool implementations writes idempotent `_orrery_managed: true` hook entries into each tool's settings JSON. `orrery use` reconciles hook state on every switch via a new internal `_reconcile-user-memory-hooks` command.

**Tech Stack:** Swift 6 (swift-tools-version: 6.0), swift-argument-parser, Swift Testing (`@Suite`/`@Test`/`#expect`), Foundation JSON encoder/decoder.

**Spec reference:** `docs/superpowers/specs/2026-05-18-user-level-memory-layer-design.md`

---

## File Map

**Create:**
- `Sources/OrreryCore/Storage/MemoryStore.swift` — shared read/write/fragment helper
- `Sources/OrreryCore/Commands/UserMemoryCommand.swift` — `orrery memory user ...` subcommands
- `Sources/OrreryCore/Commands/ReconcileUserMemoryHooksCommand.swift` — internal `_reconcile-user-memory-hooks`
- `Sources/OrreryCore/Setup/UserMemoryHookInstaller.swift` — protocol + 3 implementations
- `Tests/OrreryTests/MemoryStoreTests.swift`
- `Tests/OrreryTests/UserMemoryCommandTests.swift`
- `Tests/OrreryTests/UserMemoryHookInstallerTests.swift`
- `Tests/OrreryTests/EnvironmentStoreUserMemoryTests.swift`

**Modify:**
- `Sources/OrreryCore/Models/OrreryEnvironment.swift` — add `shareUserMemory: Bool` to both `OriginConfig` and `OrreryEnvironment`
- `Sources/OrreryCore/Storage/EnvironmentStore.swift` — `userMemoryDir`, `ensureUserMemoryHooks`, `removeUserMemoryHooks`
- `Sources/OrreryCore/MCP/MCPServer.swift` — register `orrery_user_memory_read/write`, refactor existing memory code onto `MemoryStore`
- `Sources/OrreryCore/Commands/MemoryCommand.swift` — restructure into `project` / `user` sub-groups (BREAKING rename)
- `Sources/OrreryCore/Commands/OrreryCommand.swift` — bump `OrreryVersion.current` to `"3.0.0"`, register new `ReconcileUserMemoryHooksCommand`
- `Sources/OrreryCore/Commands/CreateCommand.swift` — wizard question + `shareUserMemory` param on `createEnvironment`
- `Sources/OrreryCore/Setup/ToolSetupRunner.swift` — call `ensureUserMemoryHooks` after `addTool`
- `Sources/OrreryCore/Shell/ShellFunctionGenerator.swift` — add `orrery-bin _reconcile-user-memory-hooks` call inside the `use` shell function, after env-var export
- `Sources/OrreryCore/Resources/Localization/en.json` — new keys
- `Sources/OrreryCore/Resources/Localization/ja.json` — new keys
- `Sources/OrreryCore/Resources/Localization/zh-Hant.json` — new keys
- `Sources/OrreryCore/Resources/Localization/l10n-signatures.json` — regenerated
- `CHANGELOG.md` — v3.0.0 entry
- `docs/index.html` and `docs/zh_TW.html` — version badge

**Not in this plan (Future Work in spec):** `orrery memory user import`, custom user-memory storage path.

---

## Phase A — Foundation

### Task 1: Add `shareUserMemory` to `OriginConfig`

**Files:**
- Modify: `Sources/OrreryCore/Models/OrreryEnvironment.swift:9-29`
- Test: `Tests/OrreryTests/ModelTests.swift`

- [ ] **Step 1: Write the failing test**

Append in `Tests/OrreryTests/ModelTests.swift` (find the test suite that already covers OriginConfig; if none, add a new `@Suite("OriginConfig")` block):

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter "OriginConfig"
```

Expected: FAIL — `OriginConfig` has no `shareUserMemory` member.

- [ ] **Step 3: Add the field**

In `Sources/OrreryCore/Models/OrreryEnvironment.swift` change the `OriginConfig` struct to:

```swift
public struct OriginConfig: Codable, Sendable {
    public var isolateMemory: Bool
    public var memoryStoragePath: String?
    public var isolatedSessionTools: Set<Tool>
    public var shareUserMemory: Bool

    public init(
        isolateMemory: Bool = true,
        memoryStoragePath: String? = nil,
        isolatedSessionTools: Set<Tool> = [],
        shareUserMemory: Bool = true
    ) {
        self.isolateMemory = isolateMemory
        self.memoryStoragePath = memoryStoragePath
        self.isolatedSessionTools = isolatedSessionTools
        self.shareUserMemory = shareUserMemory
    }

    private enum CodingKeys: String, CodingKey {
        case isolateMemory, memoryStoragePath, isolatedSessionTools, shareUserMemory
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isolateMemory = try c.decodeIfPresent(Bool.self, forKey: .isolateMemory) ?? true
        memoryStoragePath = try c.decodeIfPresent(String.self, forKey: .memoryStoragePath)
        isolatedSessionTools = try c.decodeIfPresent(Set<Tool>.self, forKey: .isolatedSessionTools) ?? []
        shareUserMemory = try c.decodeIfPresent(Bool.self, forKey: .shareUserMemory) ?? true
    }

    public func isolateSessions(for tool: Tool) -> Bool {
        isolatedSessionTools.contains(tool)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```
swift test --filter "OriginConfig"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Models/OrreryEnvironment.swift Tests/OrreryTests/ModelTests.swift
git commit -m "[FEAT] OriginConfig.shareUserMemory field (default true)"
```

---

### Task 2: Add `shareUserMemory` to `OrreryEnvironment`

**Files:**
- Modify: `Sources/OrreryCore/Models/OrreryEnvironment.swift:31-end`
- Test: `Tests/OrreryTests/ModelTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter "OrreryEnvironment"
```

Expected: FAIL — no `shareUserMemory` member.

- [ ] **Step 3: Add the field**

In `Sources/OrreryCore/Models/OrreryEnvironment.swift`, find the `OrreryEnvironment` struct (around line 31). Add a stored property `public var shareUserMemory: Bool` next to `isolateMemory`. Update the `init(...)` parameter list to accept `shareUserMemory: Bool = true` and assign. Add `case shareUserMemory` to `CodingKeys`, decode with `decodeIfPresent(...) ?? true`, encode unconditionally.

- [ ] **Step 4: Run test to verify it passes**

```
swift test --filter "OrreryEnvironment"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Models/OrreryEnvironment.swift Tests/OrreryTests/ModelTests.swift
git commit -m "[FEAT] OrreryEnvironment.shareUserMemory field (default true)"
```

---

### Task 3: `EnvironmentStore.userMemoryDir`

**Files:**
- Modify: `Sources/OrreryCore/Storage/EnvironmentStore.swift` (insert near the existing memory-path helpers, around line 251)
- Test: `Tests/OrreryTests/EnvironmentStoreUserMemoryTests.swift` (new)

- [ ] **Step 1: Write the failing test**

Create `Tests/OrreryTests/EnvironmentStoreUserMemoryTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryCore

@Suite("EnvironmentStore user memory paths")
struct EnvironmentStoreUserMemoryTests {

    @Test("userMemoryDir is ~/.orrery/user/memory under the store home")
    func userMemoryDirPath() {
        let home = URL(fileURLWithPath: "/tmp/fake-orrery-home")
        let store = EnvironmentStore(homeURL: home)
        #expect(store.userMemoryDir().path == "/tmp/fake-orrery-home/user/memory")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter EnvironmentStoreUserMemoryTests
```

Expected: FAIL — `userMemoryDir` undefined.

- [ ] **Step 3: Add the method**

In `Sources/OrreryCore/Storage/EnvironmentStore.swift`, in the `// MARK: - Memory path helpers` section, append:

```swift
/// User-global memory dir: `~/.orrery/user/memory/`.
/// Independent of any env or projectKey — same path for every project, every env.
public func userMemoryDir() -> URL {
    homeURL
        .appendingPathComponent("user")
        .appendingPathComponent("memory")
}
```

- [ ] **Step 4: Run test to verify it passes**

```
swift test --filter EnvironmentStoreUserMemoryTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Storage/EnvironmentStore.swift Tests/OrreryTests/EnvironmentStoreUserMemoryTests.swift
git commit -m "[FEAT] EnvironmentStore.userMemoryDir() returns ~/.orrery/user/memory"
```

---

### Task 4: Extract `MemoryStore` helper

**Files:**
- Create: `Sources/OrreryCore/Storage/MemoryStore.swift`
- Create: `Tests/OrreryTests/MemoryStoreTests.swift`

This task introduces the shared value type without rewiring `MCPServer` yet. That refactor happens in Task 9.

- [ ] **Step 1: Write the failing test**

Create `Tests/OrreryTests/MemoryStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryCore

@Suite("MemoryStore")
struct MemoryStoreTests {
    let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-mstore-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    @Test("read() on empty dir returns empty string")
    func readEmpty() throws {
        let store = MemoryStore(directory: tmpDir)
        #expect(try store.read().memory.isEmpty)
        #expect(try store.read().fragments.isEmpty)
    }

    @Test("write(append:false) creates MEMORY.md and a fragment")
    func writeOverwrite() throws {
        let store = MemoryStore(directory: tmpDir)
        try store.write(content: "hello", append: false)

        let memory = try String(contentsOf: tmpDir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        #expect(memory == "hello")

        let fragments = try FileManager.default.contentsOfDirectory(atPath: tmpDir.appendingPathComponent("fragments").path)
        #expect(fragments.count == 1)
        let body = try String(contentsOf: tmpDir.appendingPathComponent("fragments").appendingPathComponent(fragments[0]), encoding: .utf8)
        #expect(body.contains("action: overwrite"))
        #expect(body.contains("hello"))
    }

    @Test("write(append:true) appends with leading newline + fragment")
    func writeAppend() throws {
        let store = MemoryStore(directory: tmpDir)
        try store.write(content: "first", append: false)
        try store.write(content: "second", append: true)

        let memory = try String(contentsOf: tmpDir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        #expect(memory == "first\nsecond")

        let fragments = try FileManager.default.contentsOfDirectory(atPath: tmpDir.appendingPathComponent("fragments").path)
        #expect(fragments.count == 2)
    }

    @Test("write(append:false) cleans up existing fragments after writing the new fragment")
    func writeOverwriteCleansFragments() throws {
        let store = MemoryStore(directory: tmpDir)
        try store.write(content: "a", append: true)
        try store.write(content: "b", append: true)
        try store.write(content: "consolidated", append: false)

        let fragments = try FileManager.default.contentsOfDirectory(atPath: tmpDir.appendingPathComponent("fragments").path)
        // Only the "overwrite" fragment from the consolidation call remains.
        #expect(fragments.count == 1)
        let body = try String(contentsOf: tmpDir.appendingPathComponent("fragments").appendingPathComponent(fragments[0]), encoding: .utf8)
        #expect(body.contains("action: overwrite"))
    }

    @Test("read() returns pending fragments sorted by filename")
    func readReturnsFragments() throws {
        let store = MemoryStore(directory: tmpDir)
        let fragDir = tmpDir.appendingPathComponent("fragments")
        try FileManager.default.createDirectory(at: fragDir, withIntermediateDirectories: true)
        try "frag-a-body".write(to: fragDir.appendingPathComponent("f-aaa-host.md"), atomically: true, encoding: .utf8)
        try "frag-b-body".write(to: fragDir.appendingPathComponent("f-bbb-host.md"), atomically: true, encoding: .utf8)

        let result = try store.read()
        #expect(result.fragments.map(\.filename) == ["f-aaa-host.md", "f-bbb-host.md"])
        #expect(result.fragments[0].content == "frag-a-body")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter MemoryStoreTests
```

Expected: FAIL — `MemoryStore` undefined.

- [ ] **Step 3: Implement `MemoryStore`**

Create `Sources/OrreryCore/Storage/MemoryStore.swift`:

```swift
import Foundation

/// Reads / writes a markdown memory store at `directory/`.
///
/// Layout:
/// - `directory/MEMORY.md` — canonical index, what the AI agent reads/writes.
/// - `directory/fragments/f-{id}-{peer}.md` — per-write fragment for cross-machine sync.
///
/// Used by both the project-level (per `projectKey` / env) and user-level
/// (`~/.orrery/user/memory/`) memory layers. The two layers differ only in
/// which `directory` they point at.
public struct MemoryStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public struct Fragment: Sendable, Equatable {
        public let filename: String
        public let content: String
    }

    public struct ReadResult: Sendable {
        public let memory: String
        public let fragments: [Fragment]
    }

    private var memoryFile: URL { directory.appendingPathComponent("MEMORY.md") }
    private var fragmentsDir: URL { directory.appendingPathComponent("fragments") }

    /// Read `MEMORY.md` plus any pending fragments. Both default to empty when missing.
    public func read() throws -> ReadResult {
        let fm = FileManager.default
        var memory = ""
        if fm.fileExists(atPath: memoryFile.path) {
            memory = try String(contentsOf: memoryFile, encoding: .utf8)
        }

        var fragments: [Fragment] = []
        if fm.fileExists(atPath: fragmentsDir.path) {
            let names = (try? fm.contentsOfDirectory(atPath: fragmentsDir.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".md") {
                let url = fragmentsDir.appendingPathComponent(name)
                if let body = try? String(contentsOf: url, encoding: .utf8) {
                    fragments.append(Fragment(filename: name, content: body))
                }
            }
        }
        return ReadResult(memory: memory, fragments: fragments)
    }

    /// Write or append to `MEMORY.md`, and record a fragment of the same write.
    /// When `append == false`, cleans up *prior* fragments before recording the new one — this
    /// is the consolidation contract: an overwrite means "the agent has integrated everything".
    public func write(content: String, append: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        if append, fm.fileExists(atPath: memoryFile.path) {
            let existing = try String(contentsOf: memoryFile, encoding: .utf8)
            try (existing + "\n" + content).write(to: memoryFile, atomically: true, encoding: .utf8)
        } else {
            try content.write(to: memoryFile, atomically: true, encoding: .utf8)
            cleanupFragments()
        }

        try writeFragment(content: content, action: append ? "append" : "overwrite")
    }

    /// Remove all fragments from `fragments/`. Best-effort; missing dir is fine.
    public func cleanupFragments() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: fragmentsDir.path) else { return }
        for name in names where name.hasSuffix(".md") {
            try? fm.removeItem(at: fragmentsDir.appendingPathComponent(name))
        }
    }

    private func writeFragment(content: String, action: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fragmentsDir, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let peer = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
        let id = String(UUID().uuidString.prefix(8).lowercased())
        let filename = "f-\(id)-\(peer).md"

        let body = """
        ---
        id: f-\(id)
        peer: \(peer)
        timestamp: \(timestamp)
        action: \(action)
        ---

        \(content)
        """
        try body.write(
            to: fragmentsDir.appendingPathComponent(filename),
            atomically: true,
            encoding: .utf8
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```
swift test --filter MemoryStoreTests
```

Expected: PASS (all 5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Storage/MemoryStore.swift Tests/OrreryTests/MemoryStoreTests.swift
git commit -m "[FEAT] introduce MemoryStore value type for shared read/write/fragment logic"
```

---

## Phase B — MCP & CLI plumbing

### Task 5: `MemoryStore.emit()` helper for hook output

**Files:**
- Modify: `Sources/OrreryCore/Storage/MemoryStore.swift`
- Modify: `Tests/OrreryTests/MemoryStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `MemoryStoreTests.swift`:

```swift
@Test("emit returns empty string when MEMORY.md is missing")
func emitMissing() throws {
    let store = MemoryStore(directory: tmpDir)
    #expect(try store.emit(maxBytes: 25_600) == "")
}

@Test("emit returns MEMORY.md content when small")
func emitSmall() throws {
    let store = MemoryStore(directory: tmpDir)
    try store.write(content: "tiny memory", append: false)
    let out = try store.emit(maxBytes: 25_600)
    #expect(out == "tiny memory")
}

@Test("emit appends pending fragments block")
func emitWithFragments() throws {
    let store = MemoryStore(directory: tmpDir)
    try store.write(content: "main", append: false)
    let fragDir = tmpDir.appendingPathComponent("fragments")
    try "fragbody".write(to: fragDir.appendingPathComponent("f-x-host.md"), atomically: true, encoding: .utf8)
    let out = try store.emit(maxBytes: 25_600)
    #expect(out.contains("main"))
    #expect(out.contains("Pending Memory Fragments"))
    #expect(out.contains("f-x-host.md"))
    #expect(out.contains("fragbody"))
}

@Test("emit truncates at maxBytes and appends truncation hint")
func emitTruncates() throws {
    let store = MemoryStore(directory: tmpDir)
    let big = String(repeating: "x", count: 30_000)
    try store.write(content: big, append: false)
    let out = try store.emit(maxBytes: 100)
    #expect(out.count > 100) // truncation hint adds bytes
    #expect(out.contains("truncated"))
    #expect(out.hasPrefix(String(repeating: "x", count: 100)))
}
```

The fragments-block write in the test above sidesteps `MemoryStore.write` because that would clean up fragments — fine, we're seeding state directly.

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter MemoryStoreTests
```

Expected: FAIL — `emit` undefined.

- [ ] **Step 3: Implement `emit`**

Append to `MemoryStore`:

```swift
/// Produce the hook-stdout / read-tool output: MEMORY.md content optionally followed
/// by a "Pending Memory Fragments" block, truncated to `maxBytes`.
public func emit(maxBytes: Int) throws -> String {
    let r = try read()
    var output = r.memory
    if !r.fragments.isEmpty {
        output += "\n\n---\n## Pending Memory Fragments (from sync)\n"
        output += "The following fragments were synced from other machines and need to be integrated.\n"
        output += "Please consolidate them into the memory above, then write back with append=false.\n"
        output += "After integration, the fragment files will be cleaned up automatically.\n\n"
        for f in r.fragments {
            output += "### \(f.filename)\n"
            output += f.content + "\n\n"
        }
    }
    let utf8Bytes = Array(output.utf8)
    if utf8Bytes.count <= maxBytes { return output }
    let truncated = String(decoding: utf8Bytes.prefix(maxBytes), as: UTF8.self)
    return truncated + "\n\n(truncated — read full via orrery_user_memory_read)"
}
```

- [ ] **Step 4: Run test to verify it passes**

```
swift test --filter MemoryStoreTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Storage/MemoryStore.swift Tests/OrreryTests/MemoryStoreTests.swift
git commit -m "[FEAT] MemoryStore.emit produces capped hook output with fragments block"
```

---

### Task 6: `UserMemoryCommand` skeleton with `path` / `info` / `emit`

**Files:**
- Create: `Sources/OrreryCore/Commands/UserMemoryCommand.swift`
- Create: `Tests/OrreryTests/UserMemoryCommandTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/OrreryTests/UserMemoryCommandTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryCore

@Suite("UserMemoryCommand")
struct UserMemoryCommandTests {

    @Test("emit prints empty string when no memory file exists")
    func emitEmpty() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-uemit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = EnvironmentStore(homeURL: tmp)
        let output = try UserMemoryCommand.emit(store: store)
        #expect(output == "")
    }

    @Test("emit prints MEMORY.md content when present")
    func emitWithFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-uemit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = EnvironmentStore(homeURL: tmp)
        let dir = store.userMemoryDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "global memory".write(to: dir.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        let output = try UserMemoryCommand.emit(store: store)
        #expect(output == "global memory")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter UserMemoryCommandTests
```

Expected: FAIL — `UserMemoryCommand` undefined.

- [ ] **Step 3: Implement the command + subcommands**

Create `Sources/OrreryCore/Commands/UserMemoryCommand.swift`:

```swift
import ArgumentParser
import Foundation

public struct UserMemoryCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "user",
        abstract: L10n.UserMemory.abstract,
        subcommands: [
            InfoSubcommand.self,
            PathSubcommand.self,
            EmitSubcommand.self,
            ExportSubcommand.self,
            EnableSubcommand.self,
            DisableSubcommand.self,
        ]
    )

    public init() {}

    /// Pure helper used by tests and EmitSubcommand. Returns what would be printed
    /// to stdout by `orrery memory user emit`. Capped at 25_600 bytes.
    public static func emit(store: EnvironmentStore) throws -> String {
        let dir = store.userMemoryDir()
        let store = MemoryStore(directory: dir)
        return try store.emit(maxBytes: 25_600)
    }

    public struct InfoSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: L10n.UserMemory.infoAbstract
        )
        public init() {}
        public func run() throws {
            let store = EnvironmentStore.default
            let dir = store.userMemoryDir()
            let memoryFile = dir.appendingPathComponent("MEMORY.md")
            let fm = FileManager.default
            let exists = fm.fileExists(atPath: memoryFile.path)
            let size = (try? fm.attributesOfItem(atPath: memoryFile.path)[.size] as? Int) ?? 0
            print(L10n.UserMemory.statusPath(dir.path))
            print(L10n.UserMemory.statusExists(exists, size))
        }
    }

    public struct PathSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "path",
            abstract: L10n.UserMemory.pathAbstract
        )
        public init() {}
        public func run() throws {
            print(EnvironmentStore.default.userMemoryDir().path)
        }
    }

    public struct EmitSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "emit",
            abstract: L10n.UserMemory.emitAbstract
        )
        public init() {}
        public func run() throws {
            // Best-effort: never fail a hook.
            let output = (try? UserMemoryCommand.emit(store: .default)) ?? ""
            if !output.isEmpty {
                print(output)
            }
        }
    }

    public struct ExportSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: L10n.UserMemory.exportAbstract
        )
        @Option(name: .shortAndLong, help: ArgumentHelp(L10n.UserMemory.exportOutputHelp))
        public var output: String?
        public init() {}
        public func run() throws {
            let store = EnvironmentStore.default
            let memoryFile = store.userMemoryDir().appendingPathComponent("MEMORY.md")
            guard FileManager.default.fileExists(atPath: memoryFile.path) else {
                print(L10n.UserMemory.noMemory)
                return
            }
            let content = try String(contentsOf: memoryFile, encoding: .utf8)
            let outputPath = output ?? "USER_MEMORY.md"
            let outputURL = URL(fileURLWithPath: outputPath)
            try content.write(to: outputURL, atomically: true, encoding: .utf8)
            print(L10n.UserMemory.exported(outputURL.path))
        }
    }

    // Filled in by Task 14.
    public struct EnableSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "enable",
            abstract: L10n.UserMemory.enableAbstract
        )
        public init() {}
        public func run() throws {
            throw ValidationError("not yet implemented")
        }
    }

    public struct DisableSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "disable",
            abstract: L10n.UserMemory.disableAbstract
        )
        public init() {}
        public func run() throws {
            throw ValidationError("not yet implemented")
        }
    }
}
```

The `L10n.UserMemory.*` keys do not exist yet — they'll be added in Task 8. **For now**, replace each `L10n.UserMemory.*` reference with a hard-coded English string identical to the value listed in Task 8's en.json entry. The test only depends on `EmitSubcommand` / `emit(store:)`, not on L10n.

- [ ] **Step 4: Run test to verify it passes**

```
swift test --filter UserMemoryCommandTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Commands/UserMemoryCommand.swift Tests/OrreryTests/UserMemoryCommandTests.swift
git commit -m "[FEAT] orrery memory user subcommand skeleton (info/path/emit/export)"
```

---

### Task 7: Rename project subcommands and wire `user` under `MemoryCommand`

This is the **breaking change** — existing `orrery memory info/export/isolate/share/storage` become `orrery memory project info/...`. No aliases.

**Files:**
- Modify: `Sources/OrreryCore/Commands/MemoryCommand.swift`
- Create: `Tests/OrreryTests/MemoryCommandStructureTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/OrreryTests/MemoryCommandStructureTests.swift`:

```swift
import Testing
import ArgumentParser
@testable import OrreryCore

@Suite("MemoryCommand structure")
struct MemoryCommandStructureTests {

    @Test("MemoryCommand has project and user subcommand groups")
    func subgroupsPresent() {
        let names = MemoryCommand.configuration.subcommands.map { $0._commandName }
        #expect(names.contains("project"))
        #expect(names.contains("user"))
    }

    @Test("ProjectMemoryCommand exposes info/export/isolate/share/storage")
    func projectSubcommandsExist() {
        let names = MemoryCommand.ProjectSubcommand.configuration.subcommands.map { $0._commandName }
        for expected in ["info", "export", "isolate", "share", "storage"] {
            #expect(names.contains(expected), "missing subcommand: \(expected)")
        }
    }

    @Test("orrery memory no longer has top-level info subcommand")
    func topLevelFlatRemoved() {
        let names = MemoryCommand.configuration.subcommands.map { $0._commandName }
        #expect(!names.contains("info"))
        #expect(!names.contains("isolate"))
        #expect(!names.contains("share"))
        #expect(!names.contains("storage"))
        #expect(!names.contains("export"))
    }
}

// Helper: ParsableCommand has no public `_commandName`; this extension
// surfaces the configured one for assertions.
extension ParsableCommand {
    static var _commandName: String { configuration.commandName ?? "\(self)".lowercased() }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter MemoryCommandStructureTests
```

Expected: FAIL — `ProjectSubcommand` undefined, and top-level still has `info` etc.

- [ ] **Step 3: Restructure `MemoryCommand`**

In `Sources/OrreryCore/Commands/MemoryCommand.swift`:

1. Wrap the existing `InfoSubcommand`, `ExportSubcommand`, `IsolateSubcommand`, `ShareSubcommand`, `StorageSubcommand` inside a new `public struct ProjectSubcommand: ParsableCommand` namespace with `commandName: "project"` and `subcommands: [...]` listing them.
2. Change `MemoryCommand.configuration.subcommands` to `[ProjectSubcommand.self, UserMemoryCommand.self]` (drop the old flat list).
3. Keep `MemoryCommand.run()` as the interactive top-level menu, but rebuild the menu to show two layers' status and route to either `ProjectSubcommand`'s interactive menu (extracted into `ProjectSubcommand.runInteractive()`) or `UserMemoryCommand`'s interactive flow (added in Task 13).

For the interactive `run()`, replace the body with:

```swift
public func run() throws {
    let store = EnvironmentStore.default
    let projectKey = FileManager.default.currentDirectoryPath
        .replacingOccurrences(of: "/", with: "-")
    let envName = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]

    let projectDir = store.memoryDir(projectKey: projectKey, envName: envName)
    let userDir = store.userMemoryDir()
    let userEnabled = currentEnvShareUserMemory(store: store, envName: envName)

    print(L10n.Memory.summaryProject(projectDir.path))
    print(L10n.Memory.summaryUser(userEnabled, userDir.path))
    print("")

    let selector = SingleSelect(
        title: L10n.Memory.topLevelPrompt,
        options: [L10n.Memory.manageProject, L10n.Memory.manageUser],
        selected: 0
    )
    switch selector.run() {
    case 0:
        var p = MemoryCommand.ProjectSubcommand()
        try p.run()
    case 1:
        var u = UserMemoryCommand()
        try u.run()
    default:
        break
    }
}

private func currentEnvShareUserMemory(store: EnvironmentStore, envName: String?) -> Bool {
    guard let envName else { return true }
    if envName == ReservedEnvironment.defaultName {
        return store.loadOriginConfig().shareUserMemory
    }
    return (try? store.load(named: envName))?.shareUserMemory ?? true
}
```

The old `MemoryCommand.run()` interactive code (action menu listing isolate/share/storage) moves into `ProjectSubcommand.run()` verbatim.

- [ ] **Step 4: Run test to verify it passes**

```
swift test --filter MemoryCommandStructureTests
```

Expected: PASS. Also run the full test suite to check no callers broke:

```
swift test
```

(Allow other failures only if they relate to L10n keys still missing — those are addressed in Task 8.)

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Commands/MemoryCommand.swift Tests/OrreryTests/MemoryCommandStructureTests.swift
git commit -m "[BREAKING] regroup orrery memory subcommands under project/user namespaces"
```

---

### Task 8: L10n keys for memory restructure

**Files:**
- Modify: `Sources/OrreryCore/Resources/Localization/en.json`
- Modify: `Sources/OrreryCore/Resources/Localization/ja.json`
- Modify: `Sources/OrreryCore/Resources/Localization/zh-Hant.json`
- Modify: `Sources/OrreryCore/Resources/Localization/l10n-signatures.json`

This task is straightforward data entry, but the L10n codegen plugin builds at compile time, so the build will fail if any referenced key is missing.

- [ ] **Step 1: Add the new keys**

In each locale JSON file, under the `Memory` group, add (English example shown — translate equivalents for ja and zh-Hant):

```json
"summaryProject": { "$args": "string", "en": "Project memory: %@" },
"summaryUser": { "$args": "bool,string", "en": "User memory: %@ (%@)" },
"topLevelPrompt": { "en": "What would you like to manage?" },
"manageProject": { "en": "Project memory" },
"manageUser": { "en": "User memory" }
```

(`summaryUser`'s first `%@` is a Bool — Orrery's L10n encodes Bool via "enabled"/"disabled" strings; follow the existing isolate-shared pattern in `Memory.statusMode`.)

Add a new `UserMemory` group at the top level (sibling of `Memory`):

```json
"UserMemory": {
  "abstract": { "en": "Manage user-global Orrery memory (cross-project, cross-env)." },
  "infoAbstract": { "en": "Show user memory location and status." },
  "pathAbstract": { "en": "Print the user memory directory path." },
  "emitAbstract": { "en": "Print MEMORY.md to stdout. Used by SessionStart hooks; not for humans." },
  "exportAbstract": { "en": "Export user MEMORY.md to a file." },
  "exportOutputHelp": { "en": "Output file path (default: USER_MEMORY.md)." },
  "enableAbstract": { "en": "Enable user memory in the current env (installs hooks)." },
  "disableAbstract": { "en": "Disable user memory in the current env (removes hooks)." },
  "statusPath": { "$args": "string", "en": "Path: %@" },
  "statusExists": { "$args": "bool,int", "en": "MEMORY.md exists: %@, size: %d bytes" },
  "noMemory": { "en": "No user memory to export." },
  "exported": { "$args": "string", "en": "Exported to %@" }
}
```

Re-run the L10n codegen tool (it runs as part of `swift build`):

```
swift build
```

`l10n-signatures.json` is regenerated by the build plugin — commit the regenerated version.

- [ ] **Step 2: Replace hard-coded strings**

Open `Sources/OrreryCore/Commands/UserMemoryCommand.swift` from Task 6 and replace the hard-coded English strings with their `L10n.UserMemory.*` equivalents now that the keys exist.

- [ ] **Step 3: Build and run all tests**

```
swift build
swift test
```

Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/OrreryCore/Resources/Localization/ Sources/OrreryCore/Commands/UserMemoryCommand.swift
git commit -m "[FEAT] L10n keys for orrery memory restructure + user-memory subcommands"
```

---

### Task 9: Refactor `MCPServer` onto `MemoryStore`

**Files:**
- Modify: `Sources/OrreryCore/MCP/MCPServer.swift`

No new behavior — pure refactor so the existing project-memory MCP tools route through `MemoryStore`. This sets up Task 10 / 11.

- [ ] **Step 1: Replace the read/write helpers**

In `Sources/OrreryCore/MCP/MCPServer.swift`, replace the `readMemory`, `writeMemory`, `writeFragment`, `cleanupFragments`, `pendingFragments` private helpers (and the inner `Fragment` struct) with a thin wrapper that delegates to `MemoryStore`:

```swift
private static func projectMemoryStore() -> MemoryStore {
    let projectKey = FileManager.default.currentDirectoryPath
        .replacingOccurrences(of: "/", with: "-")
    let envName = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
    let dir = EnvironmentStore.default.memoryDir(projectKey: projectKey, envName: envName)
    return MemoryStore(directory: dir)
}

private static func readMemory() -> [String: Any] {
    ensureClaudeSymlink()
    let store = projectMemoryStore()
    let result = (try? store.read()) ?? .init(memory: "", fragments: [])

    var content = result.memory
    if !result.fragments.isEmpty {
        content += "\n\n---\n## Pending Memory Fragments (from sync)\n"
        content += "The following fragments were synced from other machines and need to be integrated.\n"
        content += "Please consolidate them into the memory above, then write back with append=false.\n"
        content += "After integration, the fragment files will be cleaned up automatically.\n\n"
        for f in result.fragments {
            content += "### \(f.filename)\n"
            content += f.content + "\n\n"
        }
    }

    if content.isEmpty {
        return [
            "content": [["type": "text", "text": "(no shared memory yet)"]],
            "isError": false
        ]
    }
    return [
        "content": [["type": "text", "text": content]],
        "isError": false
    ]
}

private static func writeMemory(content: String, append: Bool) -> [String: Any] {
    ensureClaudeSymlink()
    let store = projectMemoryStore()
    do {
        try store.write(content: content, append: append)
        return [
            "content": [["type": "text", "text": "Memory updated: \(store.directory.appendingPathComponent("MEMORY.md").path)"]],
            "isError": false
        ]
    } catch {
        return toolError("Failed to write memory: \(error.localizedDescription)")
    }
}
```

Delete the now-unused helpers (`sharedMemoryFile`, `fragmentsDirectory`, `peerName`, `writeFragment`, `cleanupFragments`, `pendingFragments`, the inner `Fragment` struct).

Keep `sharedMemoryDirectory()` (still used by `ensureClaudeSymlink`) and the symlink path computation.

- [ ] **Step 2: Build and run tests**

```
swift build
swift test
```

Expected: PASS (existing MCP-related tests, if any, should still work).

- [ ] **Step 3: Commit**

```bash
git add Sources/OrreryCore/MCP/MCPServer.swift
git commit -m "[REFACTOR] route MCPServer project-memory tools through MemoryStore"
```

---

### Task 10: Register `orrery_user_memory_read` MCP tool

**Files:**
- Modify: `Sources/OrreryCore/MCP/MCPServer.swift`

- [ ] **Step 1: Add user-memory helper + register tool**

In `Sources/OrreryCore/MCP/MCPServer.swift`, near the project-memory helpers, add:

```swift
private static func userMemoryStore() -> MemoryStore {
    MemoryStore(directory: EnvironmentStore.default.userMemoryDir())
}

private static func readUserMemory() -> [String: Any] {
    let store = userMemoryStore()
    let result = (try? store.read()) ?? .init(memory: "", fragments: [])

    var content = result.memory
    if !result.fragments.isEmpty {
        content += "\n\n---\n## Pending Memory Fragments (from sync)\n"
        content += "The following fragments were synced from other machines and need to be integrated.\n"
        content += "Please consolidate them into the memory above, then write back with append=false.\n"
        content += "After integration, the fragment files will be cleaned up automatically.\n\n"
        for f in result.fragments {
            content += "### \(f.filename)\n"
            content += f.content + "\n\n"
        }
    }

    if content.isEmpty {
        return [
            "content": [["type": "text", "text": "(no user-global memory yet)"]],
            "isError": false
        ]
    }
    return [
        "content": [["type": "text", "text": content]],
        "isError": false
    ]
}
```

In the `tools/list` tool definitions block (around the existing `orrery_memory_read` entry), append:

```swift
[
    "name": "orrery_user_memory_read",
    "description": "Read the user-global Orrery memory. This memory follows you across all projects and all environments — use it for facts about who you are (the user), cross-project preferences, and tool/account references. Always read before writing to avoid overwriting existing knowledge. If pending sync fragments are present, consolidate them into MEMORY.md and write back with append=false.",
    "inputSchema": [
        "type": "object",
        "properties": [:] as [String: Any],
        "additionalProperties": false
    ]
],
```

In the `tools/call` dispatch switch, add:

```swift
case "orrery_user_memory_read":
    return readUserMemory()
```

- [ ] **Step 2: Build**

```
swift build
```

Expected: succeeds.

- [ ] **Step 3: Sanity check the tool list**

```
swift run orrery-bin mcp-server <<<'{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | head -200
```

(Or simply skip the runtime check — the build alone is a strong signal.) Expected: includes `orrery_user_memory_read` in the output.

- [ ] **Step 4: Commit**

```bash
git add Sources/OrreryCore/MCP/MCPServer.swift
git commit -m "[FEAT] register orrery_user_memory_read MCP tool"
```

---

### Task 11: Register `orrery_user_memory_write` MCP tool

**Files:**
- Modify: `Sources/OrreryCore/MCP/MCPServer.swift`

- [ ] **Step 1: Add write helper + register tool**

```swift
private static func writeUserMemory(content: String, append: Bool) -> [String: Any] {
    let store = userMemoryStore()
    do {
        try store.write(content: content, append: append)
        return [
            "content": [["type": "text", "text": "User memory updated: \(store.directory.appendingPathComponent("MEMORY.md").path)"]],
            "isError": false
        ]
    } catch {
        return toolError("Failed to write user memory: \(error.localizedDescription)")
    }
}
```

Add tool definition:

```swift
[
    "name": "orrery_user_memory_write",
    "description": "Write or append to the user-global Orrery memory. This persists across all projects/envs. Use for: user role/preferences, cross-project feedback rules, tool/account references. Default is append; set append=false to rewrite (used after consolidating fragments).",
    "inputSchema": [
        "type": "object",
        "properties": [
            "content": [
                "type": "string",
                "description": "Markdown content to write to user-global memory"
            ],
            "append": [
                "type": "boolean",
                "description": "If true, append to existing memory. If false, overwrite. Default: true"
            ]
        ],
        "required": ["content"]
    ]
],
```

Add dispatch case:

```swift
case "orrery_user_memory_write":
    let args = (params["arguments"] as? [String: Any]) ?? [:]
    let content = (args["content"] as? String) ?? ""
    let append = (args["append"] as? Bool) ?? true
    return writeUserMemory(content: content, append: append)
```

- [ ] **Step 2: Build**

```
swift build
```

Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/OrreryCore/MCP/MCPServer.swift
git commit -m "[FEAT] register orrery_user_memory_write MCP tool"
```

---

## Phase C — Hook installers

### Task 12: `UserMemoryHookInstaller` protocol + Claude installer

**Files:**
- Create: `Sources/OrreryCore/Setup/UserMemoryHookInstaller.swift`
- Create: `Tests/OrreryTests/UserMemoryHookInstallerTests.swift`

- [ ] **Step 1: Write failing tests for Claude installer**

Create `Tests/OrreryTests/UserMemoryHookInstallerTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryCore

@Suite("ClaudeHookInstaller")
struct ClaudeHookInstallerTests {
    let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-claudehook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    @Test("install on empty config creates settings.json with our hook entry")
    func installEmpty() throws {
        let installer = ClaudeHookInstaller()
        try installer.install(at: tmpDir)
        let settings = tmpDir.appendingPathComponent("settings.json")
        let body = try String(contentsOf: settings, encoding: .utf8)
        #expect(body.contains("\"command\""))
        #expect(body.contains("orrery memory user emit"))
        #expect(body.contains("\"_orrery_managed\""))
    }

    @Test("install is idempotent")
    func installIdempotent() throws {
        let installer = ClaudeHookInstaller()
        try installer.install(at: tmpDir)
        try installer.install(at: tmpDir)
        let settings = tmpDir.appendingPathComponent("settings.json")
        let data = try Data(contentsOf: settings)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]
        let sessionStart = hooks["SessionStart"] as! [[String: Any]]
        let firstMatcher = sessionStart[0]
        let entries = firstMatcher["hooks"] as! [[String: Any]]
        let managed = entries.filter { ($0["_orrery_managed"] as? Bool) == true }
        #expect(managed.count == 1)
    }

    @Test("install preserves foreign hook entries")
    func installPreservesForeign() throws {
        let settings = tmpDir.appendingPathComponent("settings.json")
        let foreign: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    [
                        "matcher": "*",
                        "hooks": [
                            ["type": "command", "command": "echo something-else"]
                        ]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: foreign, options: [.prettyPrinted])
        try data.write(to: settings)

        try ClaudeHookInstaller().install(at: tmpDir)

        let updated = try JSONSerialization.jsonObject(with: try Data(contentsOf: settings)) as! [String: Any]
        let hooks = updated["hooks"] as! [String: Any]
        let sessionStart = hooks["SessionStart"] as! [[String: Any]]
        let entries = sessionStart[0]["hooks"] as! [[String: Any]]
        #expect(entries.count == 2)
        let commands = entries.compactMap { $0["command"] as? String }
        #expect(commands.contains("echo something-else"))
        #expect(commands.contains("orrery memory user emit"))
    }

    @Test("remove only deletes _orrery_managed entries")
    func removeKeepsForeign() throws {
        let settings = tmpDir.appendingPathComponent("settings.json")
        try ClaudeHookInstaller().install(at: tmpDir)
        // Inject a foreign entry next to ours
        var json = try JSONSerialization.jsonObject(with: try Data(contentsOf: settings)) as! [String: Any]
        var hooks = json["hooks"] as! [String: Any]
        var sessionStart = hooks["SessionStart"] as! [[String: Any]]
        var entries = sessionStart[0]["hooks"] as! [[String: Any]]
        entries.append(["type": "command", "command": "echo foreign"])
        sessionStart[0]["hooks"] = entries
        hooks["SessionStart"] = sessionStart
        json["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
            .write(to: settings)

        try ClaudeHookInstaller().remove(at: tmpDir)

        let final = try JSONSerialization.jsonObject(with: try Data(contentsOf: settings)) as! [String: Any]
        let finalHooks = final["hooks"] as! [String: Any]
        let finalSessionStart = finalHooks["SessionStart"] as! [[String: Any]]
        let finalEntries = finalSessionStart[0]["hooks"] as! [[String: Any]]
        #expect(finalEntries.count == 1)
        #expect((finalEntries[0]["command"] as? String) == "echo foreign")
    }

    @Test("isInstalled true after install, false after remove")
    func isInstalledStatus() throws {
        let installer = ClaudeHookInstaller()
        #expect(!installer.isInstalled(at: tmpDir))
        try installer.install(at: tmpDir)
        #expect(installer.isInstalled(at: tmpDir))
        try installer.remove(at: tmpDir)
        #expect(!installer.isInstalled(at: tmpDir))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter ClaudeHookInstallerTests
```

Expected: FAIL — `ClaudeHookInstaller` undefined.

- [ ] **Step 3: Implement protocol + Claude installer**

Create `Sources/OrreryCore/Setup/UserMemoryHookInstaller.swift`:

```swift
import Foundation

public protocol UserMemoryHookInstaller {
    /// Idempotently add the user-memory SessionStart hook entry to this tool's config.
    func install(at configDir: URL) throws
    /// Remove only entries with `_orrery_managed: true`.
    func remove(at configDir: URL) throws
    /// Whether the managed entry is currently present.
    func isInstalled(at configDir: URL) -> Bool
}

/// Marker key the installers stamp on every entry they manage, so `remove` can
/// tell our hooks apart from user-installed ones.
let OrreryManagedKey = "_orrery_managed"
let UserMemoryHookCommand = "orrery memory user emit"

/// Shared JSON-merge logic used by all three installers — Claude, Codex (hooks.json),
/// Gemini all read JSON files with the same `hooks.SessionStart[*].hooks[*]` shape.
struct JSONHookEditor {
    let settingsFile: URL

    func loadOrEmpty() throws -> [String: Any] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsFile.path) else { return [:] }
        let data = try Data(contentsOf: settingsFile)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func save(_ root: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsFile.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: settingsFile, options: .atomic)
    }

    /// Returns `(root, sessionStart, firstMatcherIndex)` after ensuring shape exists.
    func ensureSessionStartShape(in root: inout [String: Any]) -> Int {
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        var sessionStart = (hooks["SessionStart"] as? [[String: Any]]) ?? []
        if sessionStart.isEmpty {
            sessionStart.append(["matcher": "*", "hooks": [[String: Any]]()])
        } else if sessionStart[0]["hooks"] == nil {
            sessionStart[0]["hooks"] = [[String: Any]]()
        }
        hooks["SessionStart"] = sessionStart
        root["hooks"] = hooks
        return 0
    }

    func install() throws {
        var root = try loadOrEmpty()
        _ = ensureSessionStartShape(in: &root)
        var hooks = root["hooks"] as! [String: Any]
        var sessionStart = hooks["SessionStart"] as! [[String: Any]]
        var entries = sessionStart[0]["hooks"] as! [[String: Any]]

        let alreadyPresent = entries.contains {
            ($0[OrreryManagedKey] as? Bool) == true &&
            ($0["command"] as? String) == UserMemoryHookCommand
        }
        if !alreadyPresent {
            entries.append([
                "type": "command",
                "command": UserMemoryHookCommand,
                OrreryManagedKey: true
            ])
        }
        sessionStart[0]["hooks"] = entries
        hooks["SessionStart"] = sessionStart
        root["hooks"] = hooks
        try save(root)
    }

    func remove() throws {
        var root = try loadOrEmpty()
        guard var hooks = root["hooks"] as? [String: Any],
              var sessionStart = hooks["SessionStart"] as? [[String: Any]]
        else { return }
        for i in sessionStart.indices {
            if var entries = sessionStart[i]["hooks"] as? [[String: Any]] {
                entries.removeAll { ($0[OrreryManagedKey] as? Bool) == true }
                sessionStart[i]["hooks"] = entries
            }
        }
        hooks["SessionStart"] = sessionStart
        root["hooks"] = hooks
        try save(root)
    }

    func isInstalled() -> Bool {
        guard let root = try? loadOrEmpty(),
              let hooks = root["hooks"] as? [String: Any],
              let sessionStart = hooks["SessionStart"] as? [[String: Any]]
        else { return false }
        for matcher in sessionStart {
            let entries = (matcher["hooks"] as? [[String: Any]]) ?? []
            if entries.contains(where: {
                ($0[OrreryManagedKey] as? Bool) == true &&
                ($0["command"] as? String) == UserMemoryHookCommand
            }) {
                return true
            }
        }
        return false
    }
}

public struct ClaudeHookInstaller: UserMemoryHookInstaller {
    public init() {}
    public func install(at configDir: URL) throws {
        try JSONHookEditor(settingsFile: configDir.appendingPathComponent("settings.json")).install()
    }
    public func remove(at configDir: URL) throws {
        try JSONHookEditor(settingsFile: configDir.appendingPathComponent("settings.json")).remove()
    }
    public func isInstalled(at configDir: URL) -> Bool {
        JSONHookEditor(settingsFile: configDir.appendingPathComponent("settings.json")).isInstalled()
    }
}
```

- [ ] **Step 4: Run tests**

```
swift test --filter ClaudeHookInstallerTests
```

Expected: all 5 PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Setup/UserMemoryHookInstaller.swift Tests/OrreryTests/UserMemoryHookInstallerTests.swift
git commit -m "[FEAT] UserMemoryHookInstaller protocol + ClaudeHookInstaller"
```

---

### Task 13: `CodexHookInstaller` and `GeminiHookInstaller`

**Files:**
- Modify: `Sources/OrreryCore/Setup/UserMemoryHookInstaller.swift`
- Modify: `Tests/OrreryTests/UserMemoryHookInstallerTests.swift`

**Pre-task verification:** The plan assumes Codex `hooks.json` and Gemini `settings.json` use the *same* `hooks.SessionStart[*].hooks[*]` JSON shape Claude uses. Before writing implementation code, **verify this against the current Codex CLI hook reference and Gemini CLI hook reference docs**. If the shape differs (e.g., camelCase key, flat list, different nesting), adjust `JSONHookEditor` to accept a per-tool config object describing the keys, and pass that into each installer's `init`. The test asserts (file location + idempotency + removability) stay the same regardless of schema.

- [ ] **Step 1: Write failing tests**

Append to `UserMemoryHookInstallerTests.swift`:

```swift
@Suite("CodexHookInstaller")
struct CodexHookInstallerTests {
    let tmpDir: URL
    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-codexhook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    @Test("Codex installer targets hooks.json, not config.toml")
    func codexTargetsHooksJSON() throws {
        try CodexHookInstaller().install(at: tmpDir)
        #expect(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("hooks.json").path))
        #expect(!FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("config.toml").path))
    }

    @Test("Codex installer is idempotent and removable")
    func codexLifecycle() throws {
        let installer = CodexHookInstaller()
        try installer.install(at: tmpDir)
        try installer.install(at: tmpDir)
        #expect(installer.isInstalled(at: tmpDir))
        try installer.remove(at: tmpDir)
        #expect(!installer.isInstalled(at: tmpDir))
    }
}

@Suite("GeminiHookInstaller")
struct GeminiHookInstallerTests {
    let tmpDir: URL
    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-geminihook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    @Test("Gemini installer targets settings.json in configDir")
    func geminiTargetsSettings() throws {
        try GeminiHookInstaller().install(at: tmpDir)
        #expect(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("settings.json").path))
    }

    @Test("Gemini installer is idempotent and removable")
    func geminiLifecycle() throws {
        let installer = GeminiHookInstaller()
        try installer.install(at: tmpDir)
        try installer.install(at: tmpDir)
        #expect(installer.isInstalled(at: tmpDir))
        try installer.remove(at: tmpDir)
        #expect(!installer.isInstalled(at: tmpDir))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
swift test --filter "Hook"
```

Expected: FAIL on Codex / Gemini suites.

- [ ] **Step 3: Implement the two installers**

Append to `UserMemoryHookInstaller.swift`:

```swift
public struct CodexHookInstaller: UserMemoryHookInstaller {
    public init() {}
    public func install(at configDir: URL) throws {
        try JSONHookEditor(settingsFile: configDir.appendingPathComponent("hooks.json")).install()
    }
    public func remove(at configDir: URL) throws {
        try JSONHookEditor(settingsFile: configDir.appendingPathComponent("hooks.json")).remove()
    }
    public func isInstalled(at configDir: URL) -> Bool {
        JSONHookEditor(settingsFile: configDir.appendingPathComponent("hooks.json")).isInstalled()
    }
}

public struct GeminiHookInstaller: UserMemoryHookInstaller {
    public init() {}
    public func install(at configDir: URL) throws {
        try JSONHookEditor(settingsFile: configDir.appendingPathComponent("settings.json")).install()
    }
    public func remove(at configDir: URL) throws {
        try JSONHookEditor(settingsFile: configDir.appendingPathComponent("settings.json")).remove()
    }
    public func isInstalled(at configDir: URL) -> Bool {
        JSONHookEditor(settingsFile: configDir.appendingPathComponent("settings.json")).isInstalled()
    }
}

/// Returns the installer for `tool`. Add new tools here as they gain SessionStart support.
public func userMemoryHookInstaller(for tool: Tool) -> UserMemoryHookInstaller {
    switch tool {
    case .claude:  return ClaudeHookInstaller()
    case .codex:   return CodexHookInstaller()
    case .gemini:  return GeminiHookInstaller()
    }
}
```

- [ ] **Step 4: Run tests**

```
swift test --filter "Hook"
```

Expected: all 9 hook tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Setup/UserMemoryHookInstaller.swift Tests/OrreryTests/UserMemoryHookInstallerTests.swift
git commit -m "[FEAT] CodexHookInstaller (hooks.json) + GeminiHookInstaller (settings.json)"
```

---

### Task 14: `EnvironmentStore.ensureUserMemoryHooks` / `removeUserMemoryHooks`

**Files:**
- Modify: `Sources/OrreryCore/Storage/EnvironmentStore.swift`
- Modify: `Tests/OrreryTests/EnvironmentStoreUserMemoryTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `EnvironmentStoreUserMemoryTests.swift`:

```swift
@Test("ensureUserMemoryHooks installs hooks for each installed tool")
func ensureInstallsForEachTool() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("orrery-ensurehooks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let store = EnvironmentStore(homeURL: tmp)

    var env = OrreryEnvironment(name: "e1", tools: [.claude, .codex])
    try store.save(env)
    // Pre-create tool config dirs so the installers have a place to write.
    let claudeDir = store.toolConfigDir(tool: .claude, environment: "e1")
    let codexDir = store.toolConfigDir(tool: .codex, environment: "e1")
    try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

    try store.ensureUserMemoryHooks(for: "e1")

    #expect(ClaudeHookInstaller().isInstalled(at: claudeDir))
    #expect(CodexHookInstaller().isInstalled(at: codexDir))
}

@Test("ensureUserMemoryHooks skips installation when shareUserMemory is false")
func ensureSkipsWhenDisabled() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("orrery-ensurehooks-off-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let store = EnvironmentStore(homeURL: tmp)
    var env = OrreryEnvironment(name: "e2", tools: [.claude], shareUserMemory: false)
    try store.save(env)
    let claudeDir = store.toolConfigDir(tool: .claude, environment: "e2")
    try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

    try store.ensureUserMemoryHooks(for: "e2")
    #expect(!ClaudeHookInstaller().isInstalled(at: claudeDir))
}

@Test("removeUserMemoryHooks removes from all tools")
func removeFromAllTools() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("orrery-removehooks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let store = EnvironmentStore(homeURL: tmp)
    var env = OrreryEnvironment(name: "e3", tools: [.claude, .codex])
    try store.save(env)
    let claudeDir = store.toolConfigDir(tool: .claude, environment: "e3")
    let codexDir = store.toolConfigDir(tool: .codex, environment: "e3")
    try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

    try store.ensureUserMemoryHooks(for: "e3")
    try store.removeUserMemoryHooks(for: "e3")
    #expect(!ClaudeHookInstaller().isInstalled(at: claudeDir))
    #expect(!CodexHookInstaller().isInstalled(at: codexDir))
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
swift test --filter EnvironmentStoreUserMemoryTests
```

Expected: FAIL.

- [ ] **Step 3: Add the methods**

In `Sources/OrreryCore/Storage/EnvironmentStore.swift`, near `linkOrreryMemory`, add:

```swift
/// Install the user-memory SessionStart hook into each tool config dir of this env,
/// but only if `env.shareUserMemory == true`. Idempotent.
public func ensureUserMemoryHooks(for envName: String) throws {
    let share: Bool
    let tools: [Tool]
    if envName == ReservedEnvironment.defaultName {
        share = loadOriginConfig().shareUserMemory
        tools = Tool.allCases.filter { isOriginManaged(tool: $0) }
    } else {
        let env = try load(named: envName)
        share = env.shareUserMemory
        tools = env.tools
    }
    guard share else { return }
    for tool in tools {
        let dir = (envName == ReservedEnvironment.defaultName)
            ? originConfigDir(tool: tool)
            : toolConfigDir(tool: tool, environment: envName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try userMemoryHookInstaller(for: tool).install(at: dir)
    }
}

/// Remove the managed hook entry from each tool config dir of this env.
public func removeUserMemoryHooks(for envName: String) throws {
    let tools: [Tool]
    if envName == ReservedEnvironment.defaultName {
        tools = Tool.allCases.filter { isOriginManaged(tool: $0) }
    } else {
        tools = (try load(named: envName)).tools
    }
    for tool in tools {
        let dir = (envName == ReservedEnvironment.defaultName)
            ? originConfigDir(tool: tool)
            : toolConfigDir(tool: tool, environment: envName)
        guard FileManager.default.fileExists(atPath: dir.path) else { continue }
        try userMemoryHookInstaller(for: tool).remove(at: dir)
    }
}
```

- [ ] **Step 4: Run tests**

```
swift test --filter EnvironmentStoreUserMemoryTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Storage/EnvironmentStore.swift Tests/OrreryTests/EnvironmentStoreUserMemoryTests.swift
git commit -m "[FEAT] EnvironmentStore.ensureUserMemoryHooks/removeUserMemoryHooks"
```

---

### Task 15: Wire `enable` / `disable` subcommands

**Files:**
- Modify: `Sources/OrreryCore/Commands/UserMemoryCommand.swift`
- Modify: `Tests/OrreryTests/UserMemoryCommandTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `UserMemoryCommandTests.swift`:

```swift
@Test("enable sets shareUserMemory=true and installs hooks for current env")
func enableInstallsHooks() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("orrery-enable-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let store = EnvironmentStore(homeURL: tmp)
    var env = OrreryEnvironment(name: "e", tools: [.claude], shareUserMemory: false)
    try store.save(env)
    let claudeDir = store.toolConfigDir(tool: .claude, environment: "e")
    try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

    try UserMemoryCommand.applyEnable(envName: "e", store: store)

    let updated = try store.load(named: "e")
    #expect(updated.shareUserMemory == true)
    #expect(ClaudeHookInstaller().isInstalled(at: claudeDir))
}

@Test("disable sets shareUserMemory=false and removes hooks")
func disableRemovesHooks() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("orrery-disable-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let store = EnvironmentStore(homeURL: tmp)
    var env = OrreryEnvironment(name: "e", tools: [.claude], shareUserMemory: true)
    try store.save(env)
    let claudeDir = store.toolConfigDir(tool: .claude, environment: "e")
    try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    try store.ensureUserMemoryHooks(for: "e")

    try UserMemoryCommand.applyDisable(envName: "e", store: store)

    let updated = try store.load(named: "e")
    #expect(updated.shareUserMemory == false)
    #expect(!ClaudeHookInstaller().isInstalled(at: claudeDir))
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
swift test --filter UserMemoryCommandTests
```

Expected: FAIL — `applyEnable` / `applyDisable` undefined.

- [ ] **Step 3: Implement the helpers + flesh out enable/disable subcommands**

In `Sources/OrreryCore/Commands/UserMemoryCommand.swift`, replace the placeholder `EnableSubcommand` / `DisableSubcommand` bodies and add the testable helpers:

```swift
public static func applyEnable(envName: String, store: EnvironmentStore) throws {
    if envName == ReservedEnvironment.defaultName {
        var c = store.loadOriginConfig()
        c.shareUserMemory = true
        try store.saveOriginConfig(c)
    } else {
        var env = try store.load(named: envName)
        env.shareUserMemory = true
        try store.save(env)
    }
    try store.ensureUserMemoryHooks(for: envName)
}

public static func applyDisable(envName: String, store: EnvironmentStore) throws {
    if envName == ReservedEnvironment.defaultName {
        var c = store.loadOriginConfig()
        c.shareUserMemory = false
        try store.saveOriginConfig(c)
    } else {
        var env = try store.load(named: envName)
        env.shareUserMemory = false
        try store.save(env)
    }
    try store.removeUserMemoryHooks(for: envName)
}
```

Update `EnableSubcommand.run()`:

```swift
public func run() throws {
    guard let envName = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"] else {
        throw ValidationError(L10n.UserMemory.noActiveEnv)
    }
    try UserMemoryCommand.applyEnable(envName: envName, store: .default)
    print(L10n.UserMemory.enabled(envName))
}
```

Update `DisableSubcommand.run()`:

```swift
public func run() throws {
    guard let envName = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"] else {
        throw ValidationError(L10n.UserMemory.noActiveEnv)
    }
    try UserMemoryCommand.applyDisable(envName: envName, store: .default)
    print(L10n.UserMemory.disabled(envName))
}
```

Add the three new L10n keys to `en.json` / `ja.json` / `zh-Hant.json` under `UserMemory`:

```json
"noActiveEnv": { "en": "No active environment (set ORRERY_ACTIVE_ENV or run inside orrery use)." },
"enabled": { "$args": "string", "en": "User memory enabled for %@" },
"disabled": { "$args": "string", "en": "User memory disabled for %@" }
```

- [ ] **Step 4: Run tests**

```
swift build
swift test --filter UserMemoryCommandTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Commands/UserMemoryCommand.swift Tests/OrreryTests/UserMemoryCommandTests.swift Sources/OrreryCore/Resources/Localization/
git commit -m "[FEAT] orrery memory user enable/disable wired through EnvironmentStore"
```

---

### Task 16: `_reconcile-user-memory-hooks` internal command + `orrery use` integration

**Files:**
- Create: `Sources/OrreryCore/Commands/ReconcileUserMemoryHooksCommand.swift`
- Modify: `Sources/OrreryCore/Commands/OrreryCommand.swift` (register)
- Modify: `Sources/OrreryCore/Shell/ShellFunctionGenerator.swift` (call it in `orrery use`)
- Modify: `Tests/OrreryTests/ShellFunctionGeneratorTests.swift`

- [ ] **Step 1: Implement the internal command**

Create `Sources/OrreryCore/Commands/ReconcileUserMemoryHooksCommand.swift`:

```swift
import ArgumentParser
import Foundation

/// Internal: reconcile each tool's settings.json so the SessionStart hook
/// matches the current env's `shareUserMemory` flag. Called from the shell
/// `use` function after the env vars are exported.
public struct ReconcileUserMemoryHooksCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_reconcile-user-memory-hooks",
        abstract: "Internal: ensure user-memory SessionStart hooks match the active env's shareUserMemory state.",
        shouldDisplay: false
    )

    public init() {}

    public func run() throws {
        let envName = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
            ?? ReservedEnvironment.defaultName
        let store = EnvironmentStore.default

        let share: Bool
        if envName == ReservedEnvironment.defaultName {
            share = store.loadOriginConfig().shareUserMemory
        } else {
            share = (try? store.load(named: envName))?.shareUserMemory ?? true
        }

        if share {
            try? store.ensureUserMemoryHooks(for: envName)
        } else {
            try? store.removeUserMemoryHooks(for: envName)
        }
    }
}
```

In `Sources/OrreryCore/Commands/OrreryCommand.swift`, add `ReconcileUserMemoryHooksCommand.self` to the `subcommands:` array.

- [ ] **Step 2: Patch the shell function**

In `Sources/OrreryCore/Shell/ShellFunctionGenerator.swift`, find the `_orrery_init` function and the existing `_link-memory` call:

```sh
# Ensure the Orrery memory directory is linked into Claude's auto-memory location
command orrery-bin _link-memory 2>/dev/null || true
```

Add a sibling call **before** that comment block (so reconciliation runs before symlinking):

```sh
# Reconcile user-memory SessionStart hooks for the active env.
command orrery-bin _reconcile-user-memory-hooks 2>/dev/null || true
```

Also patch the `use)` case in the dispatch. Locate it inside the multi-line string returned by `generate(...)` — grep for `use)` to find it. There are two branches that set `ORRERY_ACTIVE_ENV`: one for `orrery use origin` (default branch) and one for `orrery use <name>` (explicit env). Immediately **after each** `export ORRERY_ACTIVE_ENV=...` line, insert:

```sh
command orrery-bin _reconcile-user-memory-hooks 2>/dev/null || true
```

So every `orrery use` invocation reconciles before returning.

- [ ] **Step 3: Test shell function inclusion**

Append to `Tests/OrreryTests/ShellFunctionGeneratorTests.swift`:

```swift
@Test("generated shell function calls _reconcile-user-memory-hooks")
func shellCallsReconcile() {
    let out = ShellFunctionGenerator.generate(version: "9.9.9")
    #expect(out.contains("_reconcile-user-memory-hooks"))
}
```

- [ ] **Step 4: Build and run**

```
swift build
swift test --filter ShellFunctionGenerator
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Commands/ReconcileUserMemoryHooksCommand.swift Sources/OrreryCore/Commands/OrreryCommand.swift Sources/OrreryCore/Shell/ShellFunctionGenerator.swift Tests/OrreryTests/ShellFunctionGeneratorTests.swift
git commit -m "[FEAT] _reconcile-user-memory-hooks command + shell use integration"
```

---

## Phase D — Wizard & Setup

### Task 17: Wizard adds user-memory question to `CreateCommand`

**Files:**
- Modify: `Sources/OrreryCore/Commands/CreateCommand.swift`
- Modify: `Sources/OrreryCore/Resources/Localization/*.json`
- Modify: `Tests/OrreryTests/CreateCommandTests.swift`

- [ ] **Step 1: Write failing test**

Append to `Tests/OrreryTests/CreateCommandTests.swift`:

```swift
@Test("createEnvironment with shareUserMemory=false persists the flag")
func createPersistsShareUserMemoryFalse() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("orrery-create-shareuser-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let store = EnvironmentStore(homeURL: tmp)
    try CreateCommand.createEnvironment(
        name: "demo",
        description: "",
        tool: .claude,
        isolateSessions: false,
        isolateMemory: false,
        shareUserMemory: false,
        store: store
    )
    let env = try store.load(named: "demo")
    #expect(env.shareUserMemory == false)
}

@Test("createEnvironment defaults shareUserMemory to true")
func createDefaultsShareUserMemory() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("orrery-create-default-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let store = EnvironmentStore(homeURL: tmp)
    try CreateCommand.createEnvironment(
        name: "demo",
        description: "",
        tool: .claude,
        store: store
    )
    let env = try store.load(named: "demo")
    #expect(env.shareUserMemory == true)
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter "CreateCommand"
```

Expected: FAIL — `createEnvironment` doesn't accept `shareUserMemory`.

- [ ] **Step 3: Update `createEnvironment` signature**

In `Sources/OrreryCore/Commands/CreateCommand.swift`:

```swift
public static func createEnvironment(
    name: String,
    description: String,
    tool: Tool,
    isolateSessions: Bool = false,
    isolateMemory: Bool = false,
    shareUserMemory: Bool = true,
    store: EnvironmentStore
) throws {
    let env = OrreryEnvironment(
        name: name,
        description: description,
        isolatedSessionTools: isolateSessions ? [tool] : [],
        isolateMemory: isolateMemory,
        shareUserMemory: shareUserMemory
    )
    try store.save(env)
    try store.addTool(tool, to: name)

    if tool == .claude {
        let projectKey = FileManager.default.currentDirectoryPath
            .replacingOccurrences(of: "/", with: "-")
        let claudeConfigDir = store.toolConfigDir(tool: .claude, environment: name)
        store.linkOrreryMemory(projectKey: projectKey, envName: name, claudeConfigDir: claudeConfigDir)
    }

    if shareUserMemory {
        try store.ensureUserMemoryHooks(for: name)
    }
}
```

Also add an `@Flag` to the CLI struct (under `isolateMemory`):

```swift
@Flag(name: .long, help: ArgumentHelp(L10n.Create.userMemoryDisableHelp), inversion: .prefixedNo)
public var userMemory: Bool = true
```

Wire it into the wizard / explicit-tool paths so the flag reaches `ToolSetupRunner.runWizard` and downstream — for the existing `run()` body, append after the wizard step:

```swift
// Persist the (default-true) shareUserMemory flag onto the new env.
var saved = try store.load(named: name)
saved.shareUserMemory = userMemory
try store.save(saved)
if userMemory {
    try? store.ensureUserMemoryHooks(for: name)
}
```

Add the wizard question to `runWizard(store:)` after the tool loop returns:

```swift
let shareUserMemory = askShareUserMemory()
```

and surface it to callers (return a triple instead of a tuple — or add an instance var on the wizard helper; the cleanest is to capture into `CreateCommand` via a static var pattern, but to avoid global mutable state, add a new return value).

Concretely, change the signature:

```swift
static func runWizard(store: EnvironmentStore) -> ([ToolSetupRunner.Config], installStatusline: Bool, shareUserMemory: Bool) {
    var configs: [ToolSetupRunner.Config] = []
    var installStatusline = false
    for tool in Tool.allCases {
        guard askSetupTool(tool.rawValue, defaultYes: tool == .claude) else { continue }
        configs.append(ToolSetupRunner.runWizard(for: tool, store: store))
        if tool == .claude {
            installStatusline = askInstallStatusline()
        }
    }
    let shareUserMemory = askShareUserMemory()
    return (configs, installStatusline, shareUserMemory)
}

static func askShareUserMemory() -> Bool {
    let selector = SingleSelect(
        title: L10n.Create.askShareUserMemory,
        options: [L10n.Create.shareUserMemoryYes, L10n.Create.shareUserMemoryNo],
        selected: 0
    )
    return selector.run() == 0
}
```

Update the caller in `run()`:

```swift
let shareUserMemoryDefault: Bool
if let toolFlag = tool {
    // unchanged path
    shareUserMemoryDefault = userMemory
    configs = [...]
} else {
    let wizardResult = Self.runWizard(store: store)
    configs = wizardResult.0
    installStatusline = wizardResult.1
    shareUserMemoryDefault = wizardResult.2
}
```

Use `shareUserMemoryDefault` (instead of the `userMemory` flag) when writing back the env at the end. The `--no-user-memory` flag takes precedence: if explicitly false, force false.

- [ ] **Step 4: Add L10n keys**

In `Create` group of each locale JSON:

```json
"askShareUserMemory": { "en": "Enable user memory (cross-project personal memory layer)?" },
"shareUserMemoryYes": { "en": "Enable (recommended)" },
"shareUserMemoryNo":  { "en": "Disable for this env" },
"userMemoryDisableHelp": { "en": "Disable user memory in this env (pass --no-user-memory; default: enabled)." }
```

- [ ] **Step 5: Build and run tests**

```
swift build
swift test --filter "CreateCommand"
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrreryCore/Commands/CreateCommand.swift Sources/OrreryCore/Resources/Localization/ Tests/OrreryTests/CreateCommandTests.swift
git commit -m "[FEAT] env-create wizard + --no-user-memory flag, default enabled"
```

---

### Task 18: Origin setup wizard parity

**Files:**
- Modify: `Sources/OrreryCore/Commands/SetupCommand.swift` (or wherever the origin wizard lives)
- Modify: `Tests/OrreryTests/SetupCommandTests.swift`

- [ ] **Step 1: Locate the origin wizard**

Inspect `SetupCommand.swift` to find where the origin-side memory questions are asked. The pattern mirrors `CreateCommand.runWizard`. Identify the analog of `isolateMemory` for origin, then append `askShareUserMemory()` immediately after.

- [ ] **Step 2: Write failing test**

In `SetupCommandTests.swift`, add a test that constructs an `OriginConfig` via the setup helper (or directly) with `shareUserMemory = false`, saves it, and then runs `ensureUserMemoryHooks(for: "origin")` — assert no hooks were installed.

```swift
@Test("origin setup with shareUserMemory=false skips hook installation")
func originSkipsWhenDisabled() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("orrery-origin-su-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let store = EnvironmentStore(homeURL: tmp)
    try store.saveOriginConfig(OriginConfig(shareUserMemory: false))
    // Simulate a managed Claude
    let claudeDir = store.originConfigDir(tool: .claude)
    try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    // Pretend it's a takeover-managed symlink by creating the symlink (not strictly required
    // because isOriginManaged is the test gate; mock by bypassing — use direct install instead).
    try store.ensureUserMemoryHooks(for: ReservedEnvironment.defaultName)
    #expect(!ClaudeHookInstaller().isInstalled(at: claudeDir))
}
```

- [ ] **Step 3: Run test to verify it fails or passes**

```
swift test --filter SetupCommandTests
```

If the test already passes (because `ensureUserMemoryHooks` correctly gates on `shareUserMemory`), the gating is good — but the wizard still needs to ask the question. Verify by hand-reading `SetupCommand.swift`. If the wizard doesn't ask, write a separate test for the wizard helper.

- [ ] **Step 4: Implement the missing wizard step**

Add an analogous question + `shareUserMemory` parameter to the origin setup flow. Call `store.ensureUserMemoryHooks(for: ReservedEnvironment.defaultName)` after setup completes.

- [ ] **Step 5: Build and run tests**

```
swift build
swift test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrreryCore/Commands/SetupCommand.swift Tests/OrreryTests/SetupCommandTests.swift Sources/OrreryCore/Resources/Localization/
git commit -m "[FEAT] origin setup wizard inherits user-memory toggle"
```

---

### Task 19: `addTool` installs hook on the new tool

**Files:**
- Modify: `Sources/OrreryCore/Storage/EnvironmentStore.swift`
- Modify: `Tests/OrreryTests/EnvironmentStoreUserMemoryTests.swift`

- [ ] **Step 1: Write failing test**

Append:

```swift
@Test("addTool installs user-memory hook on the new tool when shareUserMemory=true")
func addToolInstallsHook() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("orrery-addtoolhook-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let store = EnvironmentStore(homeURL: tmp)
    var env = OrreryEnvironment(name: "e", tools: [], shareUserMemory: true)
    try store.save(env)
    try store.addTool(.claude, to: "e")
    let claudeDir = store.toolConfigDir(tool: .claude, environment: "e")
    #expect(ClaudeHookInstaller().isInstalled(at: claudeDir))
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter "addToolInstallsHook"
```

Expected: FAIL.

- [ ] **Step 3: Modify `addTool`**

In `Sources/OrreryCore/Storage/EnvironmentStore.swift`, find `addTool(_:to:)` (around line 117). After `try save(env)` at the end of the function, add:

```swift
if env.shareUserMemory {
    try? userMemoryHookInstaller(for: tool).install(at: toolDir)
}
```

- [ ] **Step 4: Run test**

```
swift test --filter "addToolInstallsHook"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Storage/EnvironmentStore.swift Tests/OrreryTests/EnvironmentStoreUserMemoryTests.swift
git commit -m "[FEAT] addTool installs user-memory hook when env opted in"
```

---

## Phase E — Release prep

### Task 20: Version bump to 3.0.0

**Files:**
- Modify: `Sources/OrreryCore/Commands/OrreryCommand.swift:4`
- Modify: `Sources/OrreryCore/MCP/MCPServer.swift:467` (the `currentVersion()` literal, if any; otherwise it uses `OrreryVersion.current` already)
- Modify: `docs/index.html` (version badge)
- Modify: `docs/zh_TW.html` (version badge)

- [ ] **Step 1: Bump `OrreryVersion`**

In `Sources/OrreryCore/Commands/OrreryCommand.swift` line 4:

```swift
public static let current = "3.0.0"
```

- [ ] **Step 2: Verify `MCPServer.currentVersion()` reads from `OrreryVersion`**

Open `MCPServer.swift:467` — it should be `OrreryVersion.current`. If a hard-coded string exists anywhere else (`grep -rn "2.6.2" Sources`), update it.

- [ ] **Step 3: Update HTML badges**

In both `docs/index.html` and `docs/zh_TW.html`, locate the version badge (shield URL or text reference to `v2.6.2`) and replace with `v3.0.0`.

- [ ] **Step 4: Build**

```
swift build
swift test
```

Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Commands/OrreryCommand.swift Sources/OrreryCore/MCP/MCPServer.swift docs/index.html docs/zh_TW.html
git commit -m "[RELEASE] v3.0.0 — user-level memory layer + memory CLI restructure"
```

(Do **not** create the git tag yet — that's the user's call after the homebrew formula is updated. The CLAUDE.md release checklist covers the tag/CI/homebrew flow.)

---

### Task 21: CHANGELOG.md entry

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Prepend the v3.0.0 entry**

At the top of `CHANGELOG.md` (under any "## Unreleased" if one exists, otherwise above the previous v2.6.2 entry), add:

```markdown
## [3.0.0] - 2026-05-19

### Added
- User-level memory layer at `~/.orrery/user/memory/`. Cross-project, cross-env
  personal memory served via:
  - SessionStart hooks installed automatically into each env's Claude / Codex /
    Gemini config (controlled by per-env `shareUserMemory`, default enabled).
  - MCP tools `orrery_user_memory_read` and `orrery_user_memory_write`.
  - New CLI subcommands `orrery memory user info / path / emit / export /
    enable / disable`.
- Wizard question on env creation: "Enable user memory?" (default: yes).
- `--no-user-memory` flag on `orrery create` to opt out from the CLI.

### Changed
- **BREAKING:** `orrery memory <info|export|isolate|share|storage>` renamed to
  `orrery memory project <info|export|isolate|share|storage>`. No aliases.
  Scripts must be updated.
- Interactive `orrery memory` now lists both project and user memory states and
  routes into the relevant submenu.

### Internal
- Introduced `MemoryStore` value type to share read/write/fragment logic
  between project- and user-level memory.
- New `UserMemoryHookInstaller` protocol with Claude / Codex / Gemini
  implementations; internal `_reconcile-user-memory-hooks` command runs on
  every `orrery use`.

### Notes
- Existing memories under `~/.orrery/shared/memory/{projectKey}/` are
  untouched.
- A future `orrery memory user import` will help lift cross-project entries
  out of the project layer; not in this release.
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "[DOCS] CHANGELOG entry for v3.0.0"
```

---

### Task 22: orrery-sync watched paths note

**Files:**
- Modify: `~/.orrery/sync-config.json` is **user-owned data**, do not touch.
- Modify: spec mentions docs — add a "Sync" subsection to `CHANGELOG.md` under v3.0.0 if not already there, pointing users at how to add the new path.

This is a one-line documentation update. The actual `orrery-sync` config is owned by the user and the separate `orrery-sync` binary repo — it's out of scope here.

- [ ] **Step 1: Append to the CHANGELOG v3.0.0 entry**

Under `### Notes`, append:

```markdown
- If you use `orrery-sync`, add `~/.orrery/user/memory/fragments/` to your
  watched-paths list to enable cross-machine sync of user memory. The fragment
  format is identical to the project layer.
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "[DOCS] note orrery-sync watched-path addition for user memory"
```

---

### Task 23: Final sanity check

- [ ] **Step 1: Run the full test suite**

```
swift test
```

Expected: all green.

- [ ] **Step 2: Run a manual smoke test**

```
swift run orrery-bin --version
# Expected: "orrery 3.0.0"

swift run orrery-bin memory --help
# Expected: shows "project" and "user" subcommands (no flat info/export/etc.)

swift run orrery-bin memory user --help
# Expected: shows info / path / emit / export / enable / disable

swift run orrery-bin memory user emit
# Expected: prints nothing on a fresh install (no MEMORY.md yet); exit 0.

mkdir -p ~/.orrery/user/memory
echo "smoke-test content" > ~/.orrery/user/memory/MEMORY.md
swift run orrery-bin memory user emit
# Expected: prints "smoke-test content"
rm ~/.orrery/user/memory/MEMORY.md
```

- [ ] **Step 3: Commit the smoke-test artifact**

Nothing to commit — this is a manual check. If any output diverges from "Expected", file a follow-up issue / fix before tagging.

---

## Spec Coverage Cross-check

| Spec requirement | Task |
|---|---|
| Storage at `~/.orrery/user/memory/` | 3 |
| MemoryStore shared helper, same schema as project | 4, 5 |
| MCP `orrery_user_memory_read/write` | 10, 11 |
| `orrery memory user *` CLI (info/path/emit/export/enable/disable) | 6, 15 |
| `orrery memory project *` rename (breaking) | 7 |
| L10n updates | 8, 15, 17 |
| `shareUserMemory` on `OriginConfig` | 1 |
| `shareUserMemory` on `OrreryEnvironment` | 2 |
| `UserMemoryHookInstaller` protocol | 12 |
| Claude / Codex / Gemini installers | 12, 13 |
| `EnvironmentStore.ensureUserMemoryHooks/removeUserMemoryHooks` | 14 |
| `addTool` installs hook lazily | 19 |
| `orrery use` reconciliation via `_reconcile-user-memory-hooks` | 16 |
| Wizard question + CLI `--no-user-memory` flag | 17 |
| Origin wizard parity | 18 |
| v3.0.0 version bump | 20 |
| CHANGELOG entry | 21 |
| orrery-sync watched-path doc note | 22 |
| `emit` truncates at 25,600 bytes with hint | 5 |
| `_orrery_managed` marker; remove preserves foreign entries | 12, 13 |
| Reconcile on every `orrery use` (incl. manual hook deletion) | 16 |
| Codex uses `hooks.json` (not `config.toml`) | 13 |
| Gemini writes real `<env>/gemini/settings.json` | 13 |

All spec requirements have at least one task; no future-work items leaked into the plan.
