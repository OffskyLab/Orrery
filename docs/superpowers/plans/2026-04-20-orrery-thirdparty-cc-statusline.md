# Orrery Thirdparty Install — cc-statusline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-04-20-orrery-thirdparty-cc-statusline-design.md`

**Goal:** Ship `orrery thirdparty install cc-statusline --env <name>` — a manifest-driven installer that writes cc-statusline's JS files and `settings.json` entries into an orrery env's claude dir, with reversible uninstall tracked by a per-env lock file.

**Architecture:** Split across three targets. `OrreryCore` owns the protocol and value types (no concrete fetchers). `OrreryThirdParty` is a new target with all implementations (`GitSource`, `ManifestRunner`, `SettingsJSONPatcher`, `BuiltInRegistry`) plus the bundled `cc-statusline` manifest. `orrery-bin` registers a runtime factory so the `thirdparty` command (living in Core) can resolve a concrete runner at call time without Core depending on ThirdParty.

**Tech Stack:** Swift 6.0, swift-testing, ArgumentParser, Foundation. **No new dependencies.** The spec shows manifests in YAML for readability; v1 ships the bundled manifest as JSON (same schema, `JSONDecoder` only) to avoid pulling Yams. Adding YAML support later is additive (new `ManifestFormat` branch).

---

## File Structure

### New files

- `Sources/OrreryCore/ThirdParty/JSONValue.swift` — recursive Codable enum modelling arbitrary JSON.
- `Sources/OrreryCore/ThirdParty/ThirdPartyPackage.swift` — `ThirdPartyPackage`, `ThirdPartySource`, `ThirdPartyStep`, `SettingsPatch`.
- `Sources/OrreryCore/ThirdParty/InstallRecord.swift` — `InstallRecord`, `SettingsPatchRecord`, `BeforeState`.
- `Sources/OrreryCore/ThirdParty/ThirdPartyRunner.swift` — `ThirdPartyRunner`, `ThirdPartyRegistry` protocols.
- `Sources/OrreryCore/ThirdParty/ThirdPartyRuntime.swift` — closure-based factory slot set by the binary at startup.
- `Sources/OrreryCore/Commands/ThirdPartyCommand.swift` — root subcommand + `install`/`uninstall`/`list`/`available` nested commands.
- `Sources/OrreryThirdParty/SettingsJSONPatcher.swift` — pure deep-merge + undo logic.
- `Sources/OrreryThirdParty/Manifest/ManifestFile.swift` — Codable structs mirroring the on-disk JSON (distinct from runtime `ThirdPartyPackage` so we can evolve the file schema).
- `Sources/OrreryThirdParty/Manifest/ManifestParser.swift` — reads `Data` → `ThirdPartyPackage`.
- `Sources/OrreryThirdParty/Manifest/BuiltInRegistry.swift` — loads bundled manifests from `Bundle.module`.
- `Sources/OrreryThirdParty/Manifests/cc-statusline.json` — bundled manifest.
- `Sources/OrreryThirdParty/Sources/ThirdPartySourceFetcher.swift` — internal protocol the runner calls.
- `Sources/OrreryThirdParty/Sources/GitSource.swift` — `git ls-remote` + `git clone --depth 1`.
- `Sources/OrreryThirdParty/Sources/VendoredSource.swift` — used only by tests.
- `Sources/OrreryThirdParty/Steps/StepExecutor.swift` — protocol each step implements (`apply`/`rollback` returning a record fragment).
- `Sources/OrreryThirdParty/Steps/CopyFileExecutor.swift`
- `Sources/OrreryThirdParty/Steps/CopyGlobExecutor.swift`
- `Sources/OrreryThirdParty/Steps/PatchSettingsExecutor.swift`
- `Sources/OrreryThirdParty/ManifestRunner.swift` — composes registry + source + step executors.
- `Sources/OrreryThirdParty/OrreryThirdPartyRuntime.swift` — one-line registration helper called by the binary.
- `Sources/orrery/main.swift` — modified to register the runtime factory before `OrreryCommand.main()`.
- `Tests/OrreryThirdPartyTests/*.swift` — one test file per production file.

### Modified files

- `Package.swift` — add `OrreryThirdParty` target, its `resources: [.process("Manifests")]`, `OrreryThirdPartyTests` target, bin depends on both.
- `Sources/OrreryCore/Commands/OrreryCommand.swift` — add `ThirdPartyCommand.self` to subcommand list.
- `Sources/OrreryCore/Resources/Localization/en.json` — add `thirdparty.*` strings.
- `Sources/OrreryCore/Resources/Localization/zh-Hant.json` — mirror keys.
- `Sources/OrreryCore/Resources/Localization/ja.json` — mirror keys.
- `Sources/OrreryCore/Resources/Localization/l10n-signatures.json` — add generated signatures for new accessors.

### File responsibility matrix

| Concern | Owner file |
|---|---|
| Arbitrary JSON values (for settings.json manipulation) | `JSONValue.swift` |
| Deep-merge + undo logic (pure, no IO) | `SettingsJSONPatcher.swift` |
| Parsing bundled manifest JSON | `ManifestFile.swift` + `ManifestParser.swift` |
| Looking up "cc-statusline" → package | `BuiltInRegistry.swift` |
| Resolving git refs + populating cache | `GitSource.swift` |
| Applying one step + returning undo info | `CopyFileExecutor.swift` etc. |
| Orchestrating an install (steps, rollback, lock file) | `ManifestRunner.swift` |
| CLI surface | `ThirdPartyCommand.swift` |
| Wiring concrete runner to CLI | `OrreryThirdPartyRuntime.swift` + `main.swift` |

---

## Task 1: Bootstrap `OrreryThirdParty` target

**Files:**
- Modify: `Package.swift`
- Create: `Sources/OrreryThirdParty/OrreryThirdPartyRuntime.swift`
- Create: `Sources/OrreryThirdParty/Manifests/.gitkeep`
- Create: `Tests/OrreryThirdPartyTests/OrreryThirdPartyTests.swift`

- [ ] **Step 1.1: Extend `Package.swift`**

Modify `Package.swift` — add the new targets and update bin dependencies:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "orrery",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "orrery-bin", targets: ["orrery-bin"]),
        .library(name: "OrreryCore", targets: ["OrreryCore"]),
        .library(name: "OrreryThirdParty", targets: ["OrreryThirdParty"]),
        .plugin(name: "L10nCodegen", targets: ["L10nCodegen"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "orrery-bin",
            dependencies: ["OrreryCore", "OrreryThirdParty"],
            path: "Sources/orrery"
        ),
        .target(
            name: "OrreryCore",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/OrreryCore",
            exclude: [
                "Resources/Localization/README.md",
                "Resources/Localization/keys.md",
            ],
            plugins: [.plugin(name: "L10nCodegen")]
        ),
        .target(
            name: "OrreryThirdParty",
            dependencies: ["OrreryCore"],
            path: "Sources/OrreryThirdParty",
            resources: [.process("Manifests")]
        ),
        .executableTarget(
            name: "L10nCodegenTool",
            path: "Plugins/L10nCodegenTool"
        ),
        .plugin(
            name: "L10nCodegen",
            capability: .buildTool(),
            dependencies: ["L10nCodegenTool"]
        ),
        .testTarget(
            name: "OrreryTests",
            dependencies: ["OrreryCore"],
            path: "Tests/OrreryTests"
        ),
        .testTarget(
            name: "OrreryThirdPartyTests",
            dependencies: ["OrreryThirdParty"],
            path: "Tests/OrreryThirdPartyTests"
        ),
    ]
)
```

- [ ] **Step 1.2: Create placeholder source file**

Create `Sources/OrreryThirdParty/OrreryThirdPartyRuntime.swift`:

```swift
import Foundation
import OrreryCore

/// Entry point the binary calls at startup to wire concrete ThirdParty
/// implementations into `OrreryCore.ThirdPartyRuntime`. Stubbed until the
/// runner lands in a later task.
public enum OrreryThirdPartyRuntime {
    public static func register() {
        // Filled in when ManifestRunner exists.
    }
}
```

- [ ] **Step 1.3: Create Manifests bundle marker**

Create an empty placeholder so `resources: [.process("Manifests")]` resolves on first build:

```bash
mkdir -p Sources/OrreryThirdParty/Manifests
touch Sources/OrreryThirdParty/Manifests/.gitkeep
```

- [ ] **Step 1.4: Create empty test file**

Create `Tests/OrreryThirdPartyTests/OrreryThirdPartyTests.swift`:

```swift
import Testing
@testable import OrreryThirdParty

@Suite("OrreryThirdParty bootstrap")
struct OrreryThirdPartyBootstrapTests {
    @Test("target compiles")
    func compiles() {
        // Presence of this test is enough. Real tests land with each impl task.
        #expect(Bool(true))
    }
}
```

- [ ] **Step 1.5: Verify build + test**

Run: `swift build && swift test --filter OrreryThirdPartyBootstrapTests`
Expected: compilation succeeds, one test passes.

- [ ] **Step 1.6: Commit**

```bash
git add Package.swift Sources/OrreryThirdParty Tests/OrreryThirdPartyTests
git commit -m "[FEAT] add OrreryThirdParty target skeleton"
```

---

## Task 2: `JSONValue` type

**Files:**
- Create: `Sources/OrreryCore/ThirdParty/JSONValue.swift`
- Create: `Tests/OrreryTests/JSONValueTests.swift`

- [ ] **Step 2.1: Write the failing tests**

Create `Tests/OrreryTests/JSONValueTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryCore

@Suite("JSONValue")
struct JSONValueTests {
    @Test("round-trips object with nested types")
    func roundTrip() throws {
        let original: JSONValue = .object([
            "name": .string("orrery"),
            "ports": .array([.number(8080), .number(9090)]),
            "enabled": .bool(true),
            "meta": .object(["kind": .null]),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == original)
    }

    @Test("number preserves integer vs double round-trip")
    func numberFidelity() throws {
        let data = Data(#"{"i": 42, "d": 1.5}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let map) = value else { Issue.record("expected object"); return }
        #expect(map["i"] == .number(42))
        #expect(map["d"] == .number(1.5))
    }

    @Test("deep equality")
    func deepEquality() {
        #expect(JSONValue.object(["a": .number(1)]) == .object(["a": .number(1)]))
        #expect(JSONValue.object(["a": .number(1)]) != .object(["a": .number(2)]))
    }
}
```

- [ ] **Step 2.2: Run tests — expect failure (type missing)**

Run: `swift test --filter JSONValueTests`
Expected: compile error, `JSONValue` not found.

- [ ] **Step 2.3: Implement `JSONValue`**

Create `Sources/OrreryCore/ThirdParty/JSONValue.swift`:

```swift
import Foundation

/// Recursive JSON model used throughout the third-party pipeline.
/// Numbers are stored as `Double` with integer-preserving encode behaviour.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .string(let s): try c.encode(s)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .number(let n):
            // Encode integers without a decimal point when possible.
            if n.truncatingRemainder(dividingBy: 1) == 0,
               n >= Double(Int64.min), n <= Double(Int64.max) {
                try c.encode(Int64(n))
            } else {
                try c.encode(n)
            }
        }
    }
}
```

- [ ] **Step 2.4: Run tests — expect pass**

Run: `swift test --filter JSONValueTests`
Expected: 3 tests pass.

- [ ] **Step 2.5: Commit**

```bash
git add Sources/OrreryCore/ThirdParty/JSONValue.swift Tests/OrreryTests/JSONValueTests.swift
git commit -m "[FEAT] add JSONValue Codable type for thirdparty pipeline"
```

---

## Task 3: `ThirdPartyPackage` value types

**Files:**
- Create: `Sources/OrreryCore/ThirdParty/ThirdPartyPackage.swift`
- Create: `Tests/OrreryTests/ThirdPartyPackageTests.swift`

- [ ] **Step 3.1: Write the failing tests**

Create `Tests/OrreryTests/ThirdPartyPackageTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryCore

@Suite("ThirdPartyPackage")
struct ThirdPartyPackageTests {
    @Test("source is codable with git case")
    func gitSourceCodec() throws {
        let src: ThirdPartySource = .git(url: "https://example.com/repo", ref: "main")
        let data = try JSONEncoder().encode(src)
        let decoded = try JSONDecoder().decode(ThirdPartySource.self, from: data)
        #expect(decoded == src)
    }

    @Test("step copyFile codec")
    func copyFileCodec() throws {
        let step: ThirdPartyStep = .copyFile(from: "a.js", to: "b.js")
        let data = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(ThirdPartyStep.self, from: data)
        #expect(decoded == step)
    }

    @Test("package aggregates id + steps")
    func packageAggregates() {
        let pkg = ThirdPartyPackage(
            id: "cc-statusline",
            displayName: "cc-statusline",
            description: "demo",
            source: .git(url: "https://example.com", ref: "main"),
            steps: [.copyFile(from: "a", to: "b")]
        )
        #expect(pkg.id == "cc-statusline")
        #expect(pkg.steps.count == 1)
    }
}
```

- [ ] **Step 3.2: Run tests — expect failure**

Run: `swift test --filter ThirdPartyPackageTests`
Expected: `ThirdPartyPackage`, `ThirdPartySource`, `ThirdPartyStep` not found.

- [ ] **Step 3.3: Implement value types**

Create `Sources/OrreryCore/ThirdParty/ThirdPartyPackage.swift`:

```swift
import Foundation

/// Declarative install plan for a third-party add-on.
public struct ThirdPartyPackage: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String
    public let source: ThirdPartySource
    public let steps: [ThirdPartyStep]

    public init(id: String, displayName: String, description: String,
                source: ThirdPartySource, steps: [ThirdPartyStep]) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.source = source
        self.steps = steps
    }
}

public enum ThirdPartySource: Codable, Equatable, Sendable {
    case git(url: String, ref: String)
    case tarball(url: String, sha256: String)       // reserved — not used in v1
    case vendored(bundlePath: String)               // test-only in v1

    private enum TypeKey: String, Codable { case git, tarball, vendored }
    private enum CodingKeys: String, CodingKey { case type, url, ref, sha256, bundlePath }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(TypeKey.self, forKey: .type) {
        case .git:
            self = .git(url: try c.decode(String.self, forKey: .url),
                        ref: try c.decode(String.self, forKey: .ref))
        case .tarball:
            self = .tarball(url: try c.decode(String.self, forKey: .url),
                            sha256: try c.decode(String.self, forKey: .sha256))
        case .vendored:
            self = .vendored(bundlePath: try c.decode(String.self, forKey: .bundlePath))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .git(let url, let ref):
            try c.encode(TypeKey.git, forKey: .type)
            try c.encode(url, forKey: .url)
            try c.encode(ref, forKey: .ref)
        case .tarball(let url, let sha):
            try c.encode(TypeKey.tarball, forKey: .type)
            try c.encode(url, forKey: .url)
            try c.encode(sha, forKey: .sha256)
        case .vendored(let path):
            try c.encode(TypeKey.vendored, forKey: .type)
            try c.encode(path, forKey: .bundlePath)
        }
    }
}

public enum ThirdPartyStep: Codable, Equatable, Sendable {
    case copyFile(from: String, to: String)
    case copyGlob(from: String, toDir: String)
    case patchSettings(file: String, patch: JSONValue)

    private enum TypeKey: String, Codable { case copyFile, copyGlob, patchSettings }
    private enum CodingKeys: String, CodingKey { case type, from, to, toDir, file, patch }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(TypeKey.self, forKey: .type) {
        case .copyFile:
            self = .copyFile(from: try c.decode(String.self, forKey: .from),
                             to: try c.decode(String.self, forKey: .to))
        case .copyGlob:
            self = .copyGlob(from: try c.decode(String.self, forKey: .from),
                             toDir: try c.decode(String.self, forKey: .toDir))
        case .patchSettings:
            self = .patchSettings(file: try c.decode(String.self, forKey: .file),
                                  patch: try c.decode(JSONValue.self, forKey: .patch))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .copyFile(let f, let t):
            try c.encode(TypeKey.copyFile, forKey: .type)
            try c.encode(f, forKey: .from); try c.encode(t, forKey: .to)
        case .copyGlob(let f, let d):
            try c.encode(TypeKey.copyGlob, forKey: .type)
            try c.encode(f, forKey: .from); try c.encode(d, forKey: .toDir)
        case .patchSettings(let f, let p):
            try c.encode(TypeKey.patchSettings, forKey: .type)
            try c.encode(f, forKey: .file); try c.encode(p, forKey: .patch)
        }
    }
}
```

- [ ] **Step 3.4: Run tests — expect pass**

Run: `swift test --filter ThirdPartyPackageTests`
Expected: 3 tests pass.

- [ ] **Step 3.5: Commit**

```bash
git add Sources/OrreryCore/ThirdParty/ThirdPartyPackage.swift Tests/OrreryTests/ThirdPartyPackageTests.swift
git commit -m "[FEAT] add ThirdPartyPackage/Source/Step value types"
```

---

## Task 4: `InstallRecord` + `SettingsPatchRecord`

**Files:**
- Create: `Sources/OrreryCore/ThirdParty/InstallRecord.swift`
- Create: `Tests/OrreryTests/InstallRecordTests.swift`

- [ ] **Step 4.1: Write the failing tests**

Create `Tests/OrreryTests/InstallRecordTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryCore

@Suite("InstallRecord")
struct InstallRecordTests {
    @Test("round-trips with all BeforeState cases")
    func roundTrip() throws {
        let record = InstallRecord(
            packageID: "cc-statusline",
            resolvedRef: String(repeating: "a", count: 40),
            manifestRef: "main",
            installedAt: Date(timeIntervalSince1970: 1_700_000_000),
            copiedFiles: ["statusline.js", "hooks/file-tracker.js"],
            patchedSettings: [
                .init(file: "settings.json", entries: [
                    .init(keyPath: ["statusLine"], before: .absent),
                    .init(keyPath: ["hooks", "UserPromptSubmit"],
                          before: .array(appendedElements: [.object(["matcher": .string(".*")])])),
                    .init(keyPath: ["model"],
                          before: .scalar(previous: .string("old"))),
                    .init(keyPath: ["env"],
                          before: .object(addedKeys: ["NEW_KEY"])),
                ])
            ]
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(InstallRecord.self, from: data)
        #expect(decoded == record)
    }
}
```

- [ ] **Step 4.2: Run tests — expect failure**

Run: `swift test --filter InstallRecordTests`
Expected: compile error, `InstallRecord` not found.

- [ ] **Step 4.3: Implement record types**

Create `Sources/OrreryCore/ThirdParty/InstallRecord.swift`:

```swift
import Foundation

public struct InstallRecord: Codable, Equatable, Sendable {
    public let packageID: String
    public let resolvedRef: String
    public let manifestRef: String
    public let installedAt: Date
    public let copiedFiles: [String]
    public let patchedSettings: [SettingsPatchRecord]

    public init(packageID: String, resolvedRef: String, manifestRef: String,
                installedAt: Date, copiedFiles: [String],
                patchedSettings: [SettingsPatchRecord]) {
        self.packageID = packageID
        self.resolvedRef = resolvedRef
        self.manifestRef = manifestRef
        self.installedAt = installedAt
        self.copiedFiles = copiedFiles
        self.patchedSettings = patchedSettings
    }
}

public struct SettingsPatchRecord: Codable, Equatable, Sendable {
    public let file: String
    public let entries: [Entry]

    public init(file: String, entries: [Entry]) {
        self.file = file
        self.entries = entries
    }

    public struct Entry: Codable, Equatable, Sendable {
        public let keyPath: [String]
        public let before: BeforeState
        public init(keyPath: [String], before: BeforeState) {
            self.keyPath = keyPath
            self.before = before
        }
    }

    public enum BeforeState: Codable, Equatable, Sendable {
        case absent
        case scalar(previous: JSONValue)
        case object(addedKeys: [String])
        case array(appendedElements: [JSONValue])

        private enum Kind: String, Codable { case absent, scalar, object, array }
        private enum Keys: String, CodingKey {
            case kind, previous, addedKeys, appendedElements
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            switch try c.decode(Kind.self, forKey: .kind) {
            case .absent:
                self = .absent
            case .scalar:
                self = .scalar(previous: try c.decode(JSONValue.self, forKey: .previous))
            case .object:
                self = .object(addedKeys: try c.decode([String].self, forKey: .addedKeys))
            case .array:
                self = .array(appendedElements: try c.decode([JSONValue].self, forKey: .appendedElements))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .absent:
                try c.encode(Kind.absent, forKey: .kind)
            case .scalar(let v):
                try c.encode(Kind.scalar, forKey: .kind)
                try c.encode(v, forKey: .previous)
            case .object(let keys):
                try c.encode(Kind.object, forKey: .kind)
                try c.encode(keys, forKey: .addedKeys)
            case .array(let els):
                try c.encode(Kind.array, forKey: .kind)
                try c.encode(els, forKey: .appendedElements)
            }
        }
    }
}
```

- [ ] **Step 4.4: Run tests — expect pass**

Run: `swift test --filter InstallRecordTests`
Expected: round-trip test passes.

- [ ] **Step 4.5: Commit**

```bash
git add Sources/OrreryCore/ThirdParty/InstallRecord.swift Tests/OrreryTests/InstallRecordTests.swift
git commit -m "[FEAT] add InstallRecord + SettingsPatchRecord codec"
```

---

## Task 5: `ThirdPartyRunner` + `ThirdPartyRegistry` protocols + `ThirdPartyRuntime` slot

**Files:**
- Create: `Sources/OrreryCore/ThirdParty/ThirdPartyRunner.swift`
- Create: `Sources/OrreryCore/ThirdParty/ThirdPartyRuntime.swift`

- [ ] **Step 5.1: Create the protocols**

Create `Sources/OrreryCore/ThirdParty/ThirdPartyRunner.swift`:

```swift
import Foundation

public enum ThirdPartyError: Error, LocalizedError {
    case packageNotFound(id: String)
    case alreadyInstalled(id: String)
    case notInstalled(id: String)
    case envNotFound(String)
    case sourceFetchFailed(reason: String)
    case stepFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .packageNotFound(let id): return "Unknown third-party package: \(id)"
        case .alreadyInstalled(let id): return "\(id) is already installed in this env"
        case .notInstalled(let id): return "\(id) is not installed in this env"
        case .envNotFound(let name): return "Environment '\(name)' not found"
        case .sourceFetchFailed(let r): return "Source fetch failed: \(r)"
        case .stepFailed(let r): return "Install step failed: \(r)"
        }
    }
}

public protocol ThirdPartyRunner: Sendable {
    func install(_ pkg: ThirdPartyPackage,
                 into env: String,
                 refOverride: String?,
                 forceRefresh: Bool) throws -> InstallRecord
    func uninstall(packageID: String, from env: String) throws
    func listInstalled(in env: String) throws -> [InstallRecord]
}

public protocol ThirdPartyRegistry: Sendable {
    func lookup(_ id: String) throws -> ThirdPartyPackage
    func listAvailable() -> [String]
}
```

- [ ] **Step 5.2: Create the runtime slot**

Create `Sources/OrreryCore/ThirdParty/ThirdPartyRuntime.swift`:

```swift
import Foundation

/// Factories registered by the binary at startup so Core-resident CLI commands
/// can obtain concrete implementations that live in `OrreryThirdParty` without
/// Core depending on that target.
public enum ThirdPartyRuntime {
    nonisolated(unsafe) public static var makeRunner: (@Sendable () -> ThirdPartyRunner)?
    nonisolated(unsafe) public static var makeRegistry: (@Sendable () -> ThirdPartyRegistry)?

    public static func runner() throws -> ThirdPartyRunner {
        guard let make = makeRunner else {
            throw ThirdPartyError.stepFailed(reason: "ThirdPartyRuntime.makeRunner not registered")
        }
        return make()
    }

    public static func registry() throws -> ThirdPartyRegistry {
        guard let make = makeRegistry else {
            throw ThirdPartyError.stepFailed(reason: "ThirdPartyRuntime.makeRegistry not registered")
        }
        return make()
    }
}
```

- [ ] **Step 5.3: Verify Core still compiles**

Run: `swift build`
Expected: success.

- [ ] **Step 5.4: Commit**

```bash
git add Sources/OrreryCore/ThirdParty/ThirdPartyRunner.swift Sources/OrreryCore/ThirdParty/ThirdPartyRuntime.swift
git commit -m "[FEAT] add ThirdPartyRunner/Registry protocols + runtime slot"
```

---

## Task 6: `SettingsJSONPatcher` — scalar overwrite + absent-key insert

**Files:**
- Create: `Sources/OrreryThirdParty/SettingsJSONPatcher.swift`
- Create: `Tests/OrreryThirdPartyTests/SettingsJSONPatcherTests.swift`

- [ ] **Step 6.1: Write the failing tests**

Create `Tests/OrreryThirdPartyTests/SettingsJSONPatcherTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("SettingsJSONPatcher — basics")
struct SettingsJSONPatcherBasicsTests {
    @Test("empty target + patch writes full object, all before = absent")
    func emptyTargetFullPatch() throws {
        var target: JSONValue = .object([:])
        let patch: JSONValue = .object([
            "statusLine": .object(["type": .string("command")]),
        ])
        let record = try SettingsJSONPatcher.apply(patch: patch, to: &target)

        #expect(target == patch)
        #expect(record.entries.count == 1)
        #expect(record.entries[0].keyPath == ["statusLine"])
        #expect(record.entries[0].before == .absent)
    }

    @Test("overwrite existing scalar records previous value")
    func scalarOverwrite() throws {
        var target: JSONValue = .object(["model": .string("old")])
        let patch: JSONValue = .object(["model": .string("new")])
        let record = try SettingsJSONPatcher.apply(patch: patch, to: &target)

        guard case .object(let out) = target else { Issue.record("expected object"); return }
        #expect(out["model"] == .string("new"))
        #expect(record.entries.count == 1)
        #expect(record.entries[0].before == .scalar(previous: .string("old")))
    }
}
```

- [ ] **Step 6.2: Run tests — expect failure**

Run: `swift test --filter SettingsJSONPatcherBasicsTests`
Expected: `SettingsJSONPatcher` not found.

- [ ] **Step 6.3: Implement minimal patcher**

Create `Sources/OrreryThirdParty/SettingsJSONPatcher.swift`:

```swift
import Foundation
import OrreryCore

/// Pure deep-merge + undo logic for `settings.json`. No IO; callers pass values in,
/// values out, and a `SettingsPatchRecord` describing exactly what was changed.
public enum SettingsJSONPatcher {
    /// Merges `patch` into `target` at the top level and records the before-state
    /// of every touched key so `unapply` can reverse it.
    public static func apply(patch: JSONValue, to target: inout JSONValue,
                             file: String = "settings.json") throws -> SettingsPatchRecord {
        guard case .object(var targetObj) = target else {
            throw ThirdPartyError.stepFailed(reason: "settings root must be an object")
        }
        guard case .object(let patchObj) = patch else {
            throw ThirdPartyError.stepFailed(reason: "patch root must be an object")
        }

        var entries: [SettingsPatchRecord.Entry] = []
        for (key, patchValue) in patchObj {
            let existing = targetObj[key]
            let (merged, before) = mergeTop(existing: existing, patch: patchValue)
            targetObj[key] = merged
            entries.append(.init(keyPath: [key], before: before))
        }
        target = .object(targetObj)
        return .init(file: file, entries: entries)
    }

    /// Top-level merge for a single key. Placeholder implementation that only
    /// handles `scalar overwrite` and `absent insert`; later tasks extend it
    /// for objects, arrays, and the hook-matcher comparator.
    private static func mergeTop(existing: JSONValue?, patch: JSONValue)
    -> (JSONValue, SettingsPatchRecord.BeforeState) {
        guard let existing else {
            return (patch, .absent)
        }
        return (patch, .scalar(previous: existing))
    }
}
```

- [ ] **Step 6.4: Run tests — expect pass**

Run: `swift test --filter SettingsJSONPatcherBasicsTests`
Expected: 2 tests pass.

- [ ] **Step 6.5: Commit**

```bash
git add Sources/OrreryThirdParty/SettingsJSONPatcher.swift Tests/OrreryThirdPartyTests/SettingsJSONPatcherTests.swift
git commit -m "[FEAT] SettingsJSONPatcher: scalar overwrite + absent insert"
```

---

## Task 7: `SettingsJSONPatcher` — recursive object merge

**Files:**
- Modify: `Sources/OrreryThirdParty/SettingsJSONPatcher.swift`
- Modify: `Tests/OrreryThirdPartyTests/SettingsJSONPatcherTests.swift`

- [ ] **Step 7.1: Append failing test**

Add to `SettingsJSONPatcherTests.swift`:

```swift
@Suite("SettingsJSONPatcher — objects")
struct SettingsJSONPatcherObjectTests {
    @Test("recursive merge only records added child keys")
    func recursiveMergeRecordsAddedKeys() throws {
        var target: JSONValue = .object([
            "env": .object(["EXISTING": .string("value")])
        ])
        let patch: JSONValue = .object([
            "env": .object(["NEW": .string("added")])
        ])
        let record = try SettingsJSONPatcher.apply(patch: patch, to: &target)

        guard case .object(let out) = target,
              case .object(let envObj) = out["env"] else {
            Issue.record("expected env object"); return
        }
        #expect(envObj["EXISTING"] == .string("value"))
        #expect(envObj["NEW"] == .string("added"))
        #expect(record.entries[0].before == .object(addedKeys: ["NEW"]))
    }

    @Test("recursive merge overwriting an existing child is recorded as scalar")
    func recursiveMergeOverwritesChildScalar() throws {
        var target: JSONValue = .object([
            "env": .object(["K": .string("old")])
        ])
        let patch: JSONValue = .object([
            "env": .object(["K": .string("new")])
        ])
        let record = try SettingsJSONPatcher.apply(patch: patch, to: &target)

        // With recursion, the key-path of the touched leaf is ["env","K"]
        // and before is .scalar(previous:"old").
        let entry = record.entries.first(where: { $0.keyPath == ["env", "K"] })
        #expect(entry?.before == .scalar(previous: .string("old")))
    }
}
```

- [ ] **Step 7.2: Run tests — expect failure**

Run: `swift test --filter SettingsJSONPatcherObjectTests`
Expected: recursive merge not implemented.

- [ ] **Step 7.3: Extend `mergeTop` + add recursion**

Replace the private helpers in `SettingsJSONPatcher.swift` with:

```swift
    public static func apply(patch: JSONValue, to target: inout JSONValue,
                             file: String = "settings.json") throws -> SettingsPatchRecord {
        guard case .object(var targetObj) = target else {
            throw ThirdPartyError.stepFailed(reason: "settings root must be an object")
        }
        guard case .object(let patchObj) = patch else {
            throw ThirdPartyError.stepFailed(reason: "patch root must be an object")
        }

        var entries: [SettingsPatchRecord.Entry] = []
        for (key, patchValue) in patchObj {
            merge(keyPath: [key],
                  target: &targetObj[key],
                  patch: patchValue,
                  entries: &entries)
        }
        target = .object(targetObj)
        return .init(file: file, entries: entries)
    }

    private static func merge(keyPath: [String],
                              target: inout JSONValue?,
                              patch: JSONValue,
                              entries: inout [SettingsPatchRecord.Entry]) {
        // Case 1: target absent → write patch, record .absent.
        guard let existing = target else {
            target = patch
            entries.append(.init(keyPath: keyPath, before: .absent))
            return
        }

        // Case 2: both sides are objects → recurse per child, track added keys.
        if case .object(var existingObj) = existing, case .object(let patchObj) = patch {
            var addedKeys: [String] = []
            for (k, v) in patchObj {
                if existingObj[k] == nil { addedKeys.append(k) }
                var child: JSONValue? = existingObj[k]
                merge(keyPath: keyPath + [k], target: &child, patch: v, entries: &entries)
                existingObj[k] = child
            }
            target = .object(existingObj)
            if !addedKeys.isEmpty {
                entries.append(.init(keyPath: keyPath, before: .object(addedKeys: addedKeys)))
            }
            return
        }

        // Case 3: fallthrough — overwrite scalar / type mismatch.
        target = patch
        entries.append(.init(keyPath: keyPath, before: .scalar(previous: existing)))
    }
```

- [ ] **Step 7.4: Run all patcher tests**

Run: `swift test --filter SettingsJSONPatcher`
Expected: all tests from task 6 + task 7 pass.

- [ ] **Step 7.5: Commit**

```bash
git add Sources/OrreryThirdParty/SettingsJSONPatcher.swift Tests/OrreryThirdPartyTests/SettingsJSONPatcherTests.swift
git commit -m "[FEAT] SettingsJSONPatcher: recursive object merge"
```

---

## Task 8: `SettingsJSONPatcher` — array append with deep-equal dedupe

**Files:**
- Modify: `Sources/OrreryThirdParty/SettingsJSONPatcher.swift`
- Modify: `Tests/OrreryThirdPartyTests/SettingsJSONPatcherTests.swift`

- [ ] **Step 8.1: Append failing tests**

Add to `SettingsJSONPatcherTests.swift`:

```swift
@Suite("SettingsJSONPatcher — arrays (deep equal)")
struct SettingsJSONPatcherArrayTests {
    @Test("appends new elements, records them")
    func appendsNewElements() throws {
        var target: JSONValue = .object(["xs": .array([.number(1)])])
        let patch: JSONValue = .object(["xs": .array([.number(1), .number(2)])])
        let record = try SettingsJSONPatcher.apply(patch: patch, to: &target)

        guard case .object(let o) = target, case .array(let xs) = o["xs"] else {
            Issue.record("expected xs array"); return
        }
        #expect(xs == [.number(1), .number(2)])
        let entry = record.entries.first(where: { $0.keyPath == ["xs"] })
        #expect(entry?.before == .array(appendedElements: [.number(2)]))
    }

    @Test("does not duplicate existing elements")
    func noDuplicates() throws {
        var target: JSONValue = .object(["xs": .array([.number(1), .number(2)])])
        let patch: JSONValue = .object(["xs": .array([.number(1)])])
        let record = try SettingsJSONPatcher.apply(patch: patch, to: &target)

        guard case .object(let o) = target, case .array(let xs) = o["xs"] else {
            Issue.record("expected xs array"); return
        }
        #expect(xs == [.number(1), .number(2)])
        // Nothing was appended — either skip recording or record empty.
        let entry = record.entries.first(where: { $0.keyPath == ["xs"] })
        #expect(entry == nil || entry?.before == .array(appendedElements: []))
    }
}
```

- [ ] **Step 8.2: Run tests — expect failure**

Run: `swift test --filter SettingsJSONPatcherArrayTests`
Expected: arrays treated as scalar overwrite.

- [ ] **Step 8.3: Extend merge to handle arrays**

In `SettingsJSONPatcher.swift`, insert **before** the "fallthrough scalar" case:

```swift
        // Case 3 (new): both sides are arrays → append-if-not-equal.
        if case .array(var existingArr) = existing, case .array(let patchArr) = patch {
            var appended: [JSONValue] = []
            for element in patchArr {
                if !existingArr.contains(where: { areEqual($0, element, keyPath: keyPath) }) {
                    existingArr.append(element)
                    appended.append(element)
                }
            }
            target = .array(existingArr)
            if !appended.isEmpty {
                entries.append(.init(keyPath: keyPath,
                                     before: .array(appendedElements: appended)))
            }
            return
        }
```

Add the comparator helper at the bottom of the file:

```swift
    /// Array equality comparator. Defaults to deep-equal; task 9 adds the
    /// hook-matcher special case.
    internal static func areEqual(_ a: JSONValue, _ b: JSONValue,
                                  keyPath: [String]) -> Bool {
        return a == b
    }
```

- [ ] **Step 8.4: Run all patcher tests**

Run: `swift test --filter SettingsJSONPatcher`
Expected: all passing.

- [ ] **Step 8.5: Commit**

```bash
git add Sources/OrreryThirdParty/SettingsJSONPatcher.swift Tests/OrreryThirdPartyTests/SettingsJSONPatcherTests.swift
git commit -m "[FEAT] SettingsJSONPatcher: array append with deep-equal dedupe"
```

---

## Task 9: `SettingsJSONPatcher` — hook-matcher comparator

**Files:**
- Modify: `Sources/OrreryThirdParty/SettingsJSONPatcher.swift`
- Modify: `Tests/OrreryThirdPartyTests/SettingsJSONPatcherTests.swift`

- [ ] **Step 9.1: Append failing tests**

Add to `SettingsJSONPatcherTests.swift`:

```swift
@Suite("SettingsJSONPatcher — hook-matcher comparator")
struct SettingsJSONPatcherHookMatcherTests {
    private func matcherEntry(_ matcher: String, commands: [String]) -> JSONValue {
        .object([
            "matcher": .string(matcher),
            "hooks": .array(commands.map {
                .object(["type": .string("command"), "command": .string($0)])
            })
        ])
    }

    @Test("identical matcher + same command set is deduped")
    func identicalEntryDeduped() throws {
        let existing = matcherEntry(".*", commands: ["node /abs/a.js"])
        let patched = matcherEntry(".*", commands: ["node /abs/a.js"])

        var target: JSONValue = .object([
            "hooks": .object(["SubagentStart": .array([existing])])
        ])
        let patch: JSONValue = .object([
            "hooks": .object(["SubagentStart": .array([patched])])
        ])
        _ = try SettingsJSONPatcher.apply(patch: patch, to: &target)

        guard case .object(let root) = target,
              case .object(let hooks) = root["hooks"],
              case .array(let arr) = hooks["SubagentStart"] else {
            Issue.record("shape mismatch"); return
        }
        #expect(arr.count == 1) // not duplicated
    }

    @Test("different matcher appends independently")
    func differentMatcherAppends() throws {
        let existing = matcherEntry("A", commands: ["node /abs/a.js"])
        let patched = matcherEntry("B", commands: ["node /abs/a.js"])

        var target: JSONValue = .object([
            "hooks": .object(["Stop": .array([existing])])
        ])
        let patch: JSONValue = .object([
            "hooks": .object(["Stop": .array([patched])])
        ])
        _ = try SettingsJSONPatcher.apply(patch: patch, to: &target)

        guard case .object(let root) = target,
              case .object(let hooks) = root["hooks"],
              case .array(let arr) = hooks["Stop"] else {
            Issue.record("shape mismatch"); return
        }
        #expect(arr.count == 2)
    }

    @Test("same matcher but different command set appends whole entry")
    func differentCommandsAppendsWholeEntry() throws {
        let existing = matcherEntry(".*", commands: ["node /abs/a.js"])
        let patched = matcherEntry(".*", commands: ["node /abs/b.js"])

        var target: JSONValue = .object([
            "hooks": .object(["PostToolUse": .array([existing])])
        ])
        let patch: JSONValue = .object([
            "hooks": .object(["PostToolUse": .array([patched])])
        ])
        _ = try SettingsJSONPatcher.apply(patch: patch, to: &target)

        guard case .object(let root) = target,
              case .object(let hooks) = root["hooks"],
              case .array(let arr) = hooks["PostToolUse"] else {
            Issue.record("shape mismatch"); return
        }
        #expect(arr.count == 2) // whole-element equality: different commands → append
    }
}
```

- [ ] **Step 9.2: Run tests — expect failure**

Run: `swift test --filter SettingsJSONPatcherHookMatcherTests`
Expected: `identicalEntryDeduped` fails — deep-equal already handles that — but `differentCommandsAppendsWholeEntry` should *pass* under deep-equal. Verify the exact failing set before coding.

If all three already pass under deep-equal, the comparator is redundant — keep task 9 anyway because matchers-with-same-commands-in-different-order or hook internal order differences need the custom rule. Add this test to force the issue:

```swift
    @Test("same matcher + same command set in different order is deduped")
    func reorderedCommandsDeduped() throws {
        let existing = matcherEntry(".*", commands: ["node /abs/a.js", "node /abs/b.js"])
        let patched = matcherEntry(".*", commands: ["node /abs/b.js", "node /abs/a.js"])

        var target: JSONValue = .object([
            "hooks": .object(["UserPromptSubmit": .array([existing])])
        ])
        let patch: JSONValue = .object([
            "hooks": .object(["UserPromptSubmit": .array([patched])])
        ])
        _ = try SettingsJSONPatcher.apply(patch: patch, to: &target)

        guard case .object(let root) = target,
              case .object(let hooks) = root["hooks"],
              case .array(let arr) = hooks["UserPromptSubmit"] else {
            Issue.record("shape mismatch"); return
        }
        #expect(arr.count == 1)
    }
```

- [ ] **Step 9.3: Implement hook-matcher comparator**

Replace `areEqual` in `SettingsJSONPatcher.swift`:

```swift
    internal static func areEqual(_ a: JSONValue, _ b: JSONValue,
                                  keyPath: [String]) -> Bool {
        // Hook-matcher shape check: objects with a `hooks` child that is
        // itself an array of `{type, command}` objects.
        if let aSig = hookMatcherSignature(a), let bSig = hookMatcherSignature(b) {
            return aSig == bSig
        }
        return a == b
    }

    private struct HookSignature: Equatable {
        let matcher: String?
        let commands: Set<String>
    }

    private static func hookMatcherSignature(_ v: JSONValue) -> HookSignature? {
        guard case .object(let obj) = v,
              case .array(let inner) = obj["hooks"] else { return nil }

        var commands = Set<String>()
        for element in inner {
            guard case .object(let eo) = element,
                  case .string(let cmd) = eo["command"] else { return nil }
            commands.insert(cmd)
        }

        let matcher: String?
        switch obj["matcher"] {
        case .some(.string(let s)): matcher = s
        case .none: matcher = nil
        default: return nil
        }

        return HookSignature(matcher: matcher, commands: commands)
    }
```

- [ ] **Step 9.4: Run all patcher tests**

Run: `swift test --filter SettingsJSONPatcher`
Expected: all passing including the reordered-commands case.

- [ ] **Step 9.5: Commit**

```bash
git add Sources/OrreryThirdParty/SettingsJSONPatcher.swift Tests/OrreryThirdPartyTests/SettingsJSONPatcherTests.swift
git commit -m "[FEAT] SettingsJSONPatcher: hook-matcher comparator"
```

---

## Task 10: `SettingsJSONPatcher` — unapply (round-trip)

**Files:**
- Modify: `Sources/OrreryThirdParty/SettingsJSONPatcher.swift`
- Modify: `Tests/OrreryThirdPartyTests/SettingsJSONPatcherTests.swift`

- [ ] **Step 10.1: Append round-trip tests**

Add to `SettingsJSONPatcherTests.swift`:

```swift
@Suite("SettingsJSONPatcher — round trip")
struct SettingsJSONPatcherRoundTripTests {
    private func roundTripMatches(original: JSONValue, patch: JSONValue) throws {
        var target = original
        let record = try SettingsJSONPatcher.apply(patch: patch, to: &target)
        try SettingsJSONPatcher.unapply(record: record, to: &target)
        #expect(target == original)
    }

    @Test("scalar overwrite round-trip")
    func scalarRoundTrip() throws {
        try roundTripMatches(
            original: .object(["model": .string("old")]),
            patch: .object(["model": .string("new")])
        )
    }

    @Test("object added-key round-trip")
    func objectRoundTrip() throws {
        try roundTripMatches(
            original: .object(["env": .object(["A": .string("1")])]),
            patch: .object(["env": .object(["B": .string("2")])])
        )
    }

    @Test("array append round-trip")
    func arrayRoundTrip() throws {
        try roundTripMatches(
            original: .object(["xs": .array([.number(1)])]),
            patch: .object(["xs": .array([.number(2), .number(3)])])
        )
    }

    @Test("absent root key round-trip")
    func absentKeyRoundTrip() throws {
        try roundTripMatches(
            original: .object([:]),
            patch: .object(["statusLine": .object(["type": .string("command")])])
        )
    }
}
```

- [ ] **Step 10.2: Run tests — expect failure**

Run: `swift test --filter SettingsJSONPatcherRoundTripTests`
Expected: `unapply` not defined.

- [ ] **Step 10.3: Implement `unapply`**

Add to `SettingsJSONPatcher.swift`:

```swift
    /// Reverses a previously recorded patch. Safe to call on a target whose
    /// schema has grown since apply (extra keys/elements the user added are
    /// left alone).
    public static func unapply(record: SettingsPatchRecord,
                               to target: inout JSONValue) throws {
        guard case .object = target else {
            throw ThirdPartyError.stepFailed(reason: "settings root must be an object")
        }
        // Reverse order so nested entries undo before their parents.
        for entry in record.entries.reversed() {
            try reverse(entry, at: entry.keyPath, in: &target)
        }
    }

    private static func reverse(_ entry: SettingsPatchRecord.Entry,
                                at path: [String],
                                in root: inout JSONValue) throws {
        guard !path.isEmpty else {
            throw ThirdPartyError.stepFailed(reason: "empty keyPath")
        }
        try mutate(at: path, in: &root) { slot in
            switch entry.before {
            case .absent:
                slot = nil
            case .scalar(let previous):
                slot = previous
            case .object(let addedKeys):
                guard case .object(var obj) = slot else { return }
                for k in addedKeys { obj.removeValue(forKey: k) }
                slot = .object(obj)
            case .array(let appended):
                guard case .array(var arr) = slot else { return }
                // Remove in reverse by exact equality (hook-matcher comparator
                // is not needed here because we stored the resolved values).
                for element in appended {
                    if let idx = arr.lastIndex(where: { $0 == element }) {
                        arr.remove(at: idx)
                    }
                }
                slot = .array(arr)
            }
        }
    }

    private static func mutate(at path: [String],
                               in root: inout JSONValue,
                               _ transform: (inout JSONValue?) -> Void) throws {
        if path.count == 1 {
            guard case .object(var obj) = root else {
                throw ThirdPartyError.stepFailed(reason: "expected object at root")
            }
            var slot: JSONValue? = obj[path[0]]
            transform(&slot)
            if let slot { obj[path[0]] = slot } else { obj.removeValue(forKey: path[0]) }
            root = .object(obj)
            return
        }
        guard case .object(var obj) = root,
              var child = obj[path[0]] else {
            return // nothing to reverse — the user already cleaned up
        }
        try mutate(at: Array(path.dropFirst()), in: &child, transform)
        obj[path[0]] = child
        root = .object(obj)
    }
```

- [ ] **Step 10.4: Run all patcher tests**

Run: `swift test --filter SettingsJSONPatcher`
Expected: all passing, including 4 round-trip cases.

- [ ] **Step 10.5: Commit**

```bash
git add Sources/OrreryThirdParty/SettingsJSONPatcher.swift Tests/OrreryThirdPartyTests/SettingsJSONPatcherTests.swift
git commit -m "[FEAT] SettingsJSONPatcher: unapply with round-trip tests"
```

---

## Task 11: Manifest file schema + parser

**Files:**
- Create: `Sources/OrreryThirdParty/Manifest/ManifestFile.swift`
- Create: `Sources/OrreryThirdParty/Manifest/ManifestParser.swift`
- Create: `Tests/OrreryThirdPartyTests/ManifestParserTests.swift`

- [ ] **Step 11.1: Write the failing tests**

Create `Tests/OrreryThirdPartyTests/ManifestParserTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("ManifestParser")
struct ManifestParserTests {
    private let ccStatuslineJSON = """
    {
      "id": "cc-statusline",
      "displayName": "cc-statusline",
      "description": "demo",
      "source": { "type": "git", "url": "https://example.com/x", "ref": "main" },
      "steps": [
        { "type": "copyFile", "from": "a.js", "to": "b.js" },
        { "type": "copyGlob", "from": "hooks/*.js", "toDir": "hooks" },
        { "type": "patchSettings", "file": "settings.json", "patch": { "statusLine": {} } }
      ]
    }
    """

    @Test("parses valid manifest into ThirdPartyPackage")
    func parsesValid() throws {
        let pkg = try ManifestParser.parse(Data(ccStatuslineJSON.utf8))
        #expect(pkg.id == "cc-statusline")
        #expect(pkg.steps.count == 3)
        if case .git(_, let ref) = pkg.source { #expect(ref == "main") } else { Issue.record("expected git") }
    }

    @Test("missing source.url throws")
    func missingURLThrows() throws {
        let bad = """
        { "id": "x", "displayName": "x", "description": "",
          "source": { "type": "git", "ref": "main" },
          "steps": [] }
        """
        #expect(throws: (any Error).self) {
            _ = try ManifestParser.parse(Data(bad.utf8))
        }
    }

    @Test("unknown step type throws")
    func unknownStepThrows() throws {
        let bad = """
        { "id": "x", "displayName": "x", "description": "",
          "source": { "type": "git", "url": "u", "ref": "main" },
          "steps": [ { "type": "unknownStep" } ] }
        """
        #expect(throws: (any Error).self) {
            _ = try ManifestParser.parse(Data(bad.utf8))
        }
    }
}
```

- [ ] **Step 11.2: Run tests — expect failure**

Run: `swift test --filter ManifestParserTests`
Expected: `ManifestParser` not found.

- [ ] **Step 11.3: Implement parser**

Create `Sources/OrreryThirdParty/Manifest/ManifestFile.swift`:

```swift
import Foundation
import OrreryCore

/// On-disk representation of a manifest. Kept separate from
/// `ThirdPartyPackage` so the file schema can evolve (new fields, deprecations)
/// without changing the runtime type used everywhere else.
struct ManifestFile: Decodable {
    let id: String
    let displayName: String
    let description: String
    let source: ThirdPartySource
    let steps: [ThirdPartyStep]
}

extension ManifestFile {
    func toPackage() -> ThirdPartyPackage {
        ThirdPartyPackage(
            id: id,
            displayName: displayName,
            description: description,
            source: source,
            steps: steps
        )
    }
}
```

Create `Sources/OrreryThirdParty/Manifest/ManifestParser.swift`:

```swift
import Foundation
import OrreryCore

public enum ManifestParser {
    public static func parse(_ data: Data) throws -> ThirdPartyPackage {
        do {
            let file = try JSONDecoder().decode(ManifestFile.self, from: data)
            return file.toPackage()
        } catch {
            throw ThirdPartyError.packageNotFound(id: "(manifest parse failed: \(error))")
        }
    }
}
```

- [ ] **Step 11.4: Run tests — expect pass**

Run: `swift test --filter ManifestParserTests`
Expected: 3 tests pass.

- [ ] **Step 11.5: Commit**

```bash
git add Sources/OrreryThirdParty/Manifest Tests/OrreryThirdPartyTests/ManifestParserTests.swift
git commit -m "[FEAT] ManifestParser + ManifestFile schema"
```

---

## Task 12: Bundled `cc-statusline.json` + `BuiltInRegistry`

**Files:**
- Create: `Sources/OrreryThirdParty/Manifests/cc-statusline.json`
- Create: `Sources/OrreryThirdParty/Manifest/BuiltInRegistry.swift`
- Create: `Tests/OrreryThirdPartyTests/BuiltInRegistryTests.swift`
- Delete: `Sources/OrreryThirdParty/Manifests/.gitkeep`

- [ ] **Step 12.1: Create the bundled manifest**

Create `Sources/OrreryThirdParty/Manifests/cc-statusline.json`:

```json
{
  "id": "cc-statusline",
  "displayName": "cc-statusline",
  "description": "Full statusline dashboard for Claude Code.",
  "source": {
    "type": "git",
    "url": "https://github.com/NYCU-Chung/cc-statusline",
    "ref": "main"
  },
  "steps": [
    { "type": "copyFile", "from": "statusline.js", "to": "statusline.js" },
    { "type": "copyGlob", "from": "hooks/*.js", "toDir": "hooks" },
    {
      "type": "patchSettings",
      "file": "settings.json",
      "patch": {
        "statusLine": {
          "type": "command",
          "command": "node <CLAUDE_DIR>/statusline.js",
          "refreshInterval": 30
        },
        "hooks": {
          "SubagentStart": [
            { "matcher": ".*", "hooks": [{ "type": "command", "command": "node <CLAUDE_DIR>/hooks/subagent-tracker.js" }] }
          ],
          "SubagentStop": [
            { "matcher": ".*", "hooks": [{ "type": "command", "command": "node <CLAUDE_DIR>/hooks/subagent-tracker.js" }] }
          ],
          "PreCompact": [
            { "matcher": ".*", "hooks": [{ "type": "command", "command": "node <CLAUDE_DIR>/hooks/compact-monitor.js" }] }
          ],
          "UserPromptSubmit": [
            {
              "hooks": [
                { "type": "command", "command": "node <CLAUDE_DIR>/hooks/message-tracker.js" },
                { "type": "command", "command": "node <CLAUDE_DIR>/hooks/summary-updater.js" }
              ]
            }
          ],
          "Stop": [
            { "matcher": "*", "hooks": [{ "type": "command", "command": "node <CLAUDE_DIR>/hooks/message-tracker.js" }] }
          ],
          "PostToolUse": [
            { "matcher": "Write|Edit", "hooks": [{ "type": "command", "command": "node <CLAUDE_DIR>/hooks/file-tracker.js" }] }
          ]
        }
      }
    }
  ]
}
```

```bash
rm Sources/OrreryThirdParty/Manifests/.gitkeep
```

- [ ] **Step 12.2: Write the failing tests**

Create `Tests/OrreryThirdPartyTests/BuiltInRegistryTests.swift`:

```swift
import Testing
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("BuiltInRegistry")
struct BuiltInRegistryTests {
    @Test("lookup cc-statusline succeeds")
    func lookupCCStatusline() throws {
        let reg = BuiltInRegistry()
        let pkg = try reg.lookup("cc-statusline")
        #expect(pkg.id == "cc-statusline")
        #expect(pkg.steps.count == 3)
    }

    @Test("lookup unknown throws packageNotFound")
    func unknownThrows() throws {
        let reg = BuiltInRegistry()
        #expect(throws: ThirdPartyError.self) {
            _ = try reg.lookup("does-not-exist")
        }
    }

    @Test("listAvailable contains cc-statusline")
    func lists() {
        let reg = BuiltInRegistry()
        #expect(reg.listAvailable().contains("cc-statusline"))
    }
}
```

- [ ] **Step 12.3: Run tests — expect failure**

Run: `swift test --filter BuiltInRegistryTests`
Expected: `BuiltInRegistry` not found.

- [ ] **Step 12.4: Implement the registry**

Create `Sources/OrreryThirdParty/Manifest/BuiltInRegistry.swift`:

```swift
import Foundation
import OrreryCore

public struct BuiltInRegistry: ThirdPartyRegistry {
    // Map of package id → manifest resource name (without .json). When more
    // add-ons ship, extend this table and add the matching Manifests/*.json.
    private static let table: [String: String] = [
        "cc-statusline": "cc-statusline",
    ]

    public init() {}

    public func lookup(_ id: String) throws -> ThirdPartyPackage {
        guard let resource = Self.table[id] else {
            throw ThirdPartyError.packageNotFound(id: id)
        }
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            throw ThirdPartyError.packageNotFound(id: id)
        }
        return try ManifestParser.parse(data)
    }

    public func listAvailable() -> [String] {
        Array(Self.table.keys).sorted()
    }
}
```

- [ ] **Step 12.5: Run tests — expect pass**

Run: `swift test --filter BuiltInRegistryTests`
Expected: 3 tests pass.

- [ ] **Step 12.6: Commit**

```bash
git add Sources/OrreryThirdParty/Manifest/BuiltInRegistry.swift Sources/OrreryThirdParty/Manifests/cc-statusline.json Tests/OrreryThirdPartyTests/BuiltInRegistryTests.swift
git rm Sources/OrreryThirdParty/Manifests/.gitkeep
git commit -m "[FEAT] ship cc-statusline manifest + BuiltInRegistry"
```

---

## Task 13: `GitSource` — ref resolution + clone + cache reuse

**Files:**
- Create: `Sources/OrreryThirdParty/Sources/ThirdPartySourceFetcher.swift`
- Create: `Sources/OrreryThirdParty/Sources/GitSource.swift`
- Create: `Tests/OrreryThirdPartyTests/GitSourceTests.swift`

- [ ] **Step 13.1: Define the fetcher protocol**

Create `Sources/OrreryThirdParty/Sources/ThirdPartySourceFetcher.swift`:

```swift
import Foundation
import OrreryCore

/// The runner calls this to get a local directory containing the source files
/// the steps will copy from. Implementations handle caching internally.
protocol ThirdPartySourceFetcher: Sendable {
    /// Returns `(localDir, resolvedRef)`.
    func fetch(source: ThirdPartySource,
               cacheRoot: URL,
               packageID: String,
               refOverride: String?,
               forceRefresh: Bool) throws -> (URL, String)
}
```

- [ ] **Step 13.2: Write the failing tests**

Create `Tests/OrreryThirdPartyTests/GitSourceTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("GitSource")
struct GitSourceTests {
    private func tempCacheRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-git-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("40-char hex ref is treated as resolved SHA")
    func recognisesResolvedSHA() throws {
        let cache = try tempCacheRoot()
        defer { try? FileManager.default.removeItem(at: cache) }
        let git = GitSource()
        let sha = String(repeating: "a", count: 40)
        #expect(git.isResolvedSHA(sha))
        #expect(git.isResolvedSHA("main") == false)
        #expect(git.isResolvedSHA("aa") == false)
    }

    @Test("cache key includes resolved SHA")
    func cacheKey() throws {
        let cache = try tempCacheRoot()
        defer { try? FileManager.default.removeItem(at: cache) }
        let git = GitSource()
        let sha = String(repeating: "b", count: 40)
        let dir = git.cacheDir(root: cache, packageID: "cc-statusline", sha: sha)
        #expect(dir.path.hasSuffix("cc-statusline/@\(sha)"))
    }
}
```

Real-clone integration tests are deferred to task 20 (gated by SKIP_NETWORK_TESTS).

- [ ] **Step 13.3: Run tests — expect failure**

Run: `swift test --filter GitSourceTests`
Expected: `GitSource` not found.

- [ ] **Step 13.4: Implement `GitSource`**

Create `Sources/OrreryThirdParty/Sources/GitSource.swift`:

```swift
import Foundation
import OrreryCore

public struct GitSource: ThirdPartySourceFetcher {
    public init() {}

    /// True when `ref` matches `[0-9a-f]{40}`.
    func isResolvedSHA(_ ref: String) -> Bool {
        guard ref.count == 40 else { return false }
        return ref.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    func cacheDir(root: URL, packageID: String, sha: String) -> URL {
        root.appendingPathComponent(packageID).appendingPathComponent("@\(sha)")
    }

    func fetch(source: ThirdPartySource,
               cacheRoot: URL,
               packageID: String,
               refOverride: String?,
               forceRefresh: Bool) throws -> (URL, String) {
        guard case .git(let url, let manifestRef) = source else {
            throw ThirdPartyError.sourceFetchFailed(reason: "GitSource only supports git source")
        }
        let requestedRef = refOverride ?? manifestRef
        let sha = try resolveSHA(url: url, ref: requestedRef)
        let dir = cacheDir(root: cacheRoot, packageID: packageID, sha: sha)

        let fm = FileManager.default
        if forceRefresh, fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try clone(url: url, ref: requestedRef, sha: sha, into: dir)
        }
        return (dir, sha)
    }

    private func resolveSHA(url: String, ref: String) throws -> String {
        if isResolvedSHA(ref) { return ref }
        let out = try runGit(["ls-remote", url, ref])
        // ls-remote output: "<sha>\t<ref>\n"; take the first SHA token.
        guard let line = out.split(separator: "\n").first,
              let sha = line.split(separator: "\t").first,
              sha.count == 40 else {
            throw ThirdPartyError.sourceFetchFailed(reason: "git ls-remote returned no match for \(ref)")
        }
        return String(sha)
    }

    private func clone(url: String, ref: String, sha: String, into dir: URL) throws {
        // Two cases:
        //  1. ref is a branch/tag — clone with --depth 1 --branch.
        //  2. ref is a pure SHA — clone default branch then checkout SHA.
        if isResolvedSHA(ref) {
            _ = try runGit(["clone", "--filter=blob:none", "--no-checkout", url, dir.path])
            _ = try runGit(["-C", dir.path, "checkout", sha])
        } else {
            _ = try runGit(["clone", "--depth", "1", "--branch", ref, url, dir.path])
        }
    }

    private func runGit(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? "git failed"
            throw ThirdPartyError.sourceFetchFailed(reason: msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
```

- [ ] **Step 13.5: Run tests — expect pass**

Run: `swift test --filter GitSourceTests`
Expected: 2 tests pass.

- [ ] **Step 13.6: Commit**

```bash
git add Sources/OrreryThirdParty/Sources Tests/OrreryThirdPartyTests/GitSourceTests.swift
git commit -m "[FEAT] GitSource with ls-remote resolve + depth-1 clone caching"
```

---

## Task 14: `VendoredSource` (used by end-to-end tests)

**Files:**
- Create: `Sources/OrreryThirdParty/Sources/VendoredSource.swift`

- [ ] **Step 14.1: Implement and commit together (no test — will be exercised by task 20)**

Create `Sources/OrreryThirdParty/Sources/VendoredSource.swift`:

```swift
import Foundation
import OrreryCore

/// Source fetcher that just points at an on-disk directory. Used by the
/// end-to-end test in task 20 to avoid a real network clone. Not wired into
/// the production runner path.
public struct VendoredSource: ThirdPartySourceFetcher {
    public init() {}

    func fetch(source: ThirdPartySource,
               cacheRoot: URL,
               packageID: String,
               refOverride: String?,
               forceRefresh: Bool) throws -> (URL, String) {
        guard case .vendored(let path) = source else {
            throw ThirdPartyError.sourceFetchFailed(reason: "VendoredSource only supports vendored source")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ThirdPartyError.sourceFetchFailed(reason: "vendored path not found: \(path)")
        }
        // Deterministic pseudo-SHA so lock-file shape is identical to git path.
        let sha = String(repeating: "0", count: 40)
        return (url, sha)
    }
}
```

- [ ] **Step 14.2: Build**

Run: `swift build`
Expected: success.

- [ ] **Step 14.3: Commit**

```bash
git add Sources/OrreryThirdParty/Sources/VendoredSource.swift
git commit -m "[FEAT] VendoredSource for hermetic integration tests"
```

---

## Task 15: Step executors — copyFile + copyGlob

**Files:**
- Create: `Sources/OrreryThirdParty/Steps/StepExecutor.swift`
- Create: `Sources/OrreryThirdParty/Steps/CopyFileExecutor.swift`
- Create: `Sources/OrreryThirdParty/Steps/CopyGlobExecutor.swift`
- Create: `Tests/OrreryThirdPartyTests/CopyExecutorTests.swift`

- [ ] **Step 15.1: Write the failing tests**

Create `Tests/OrreryThirdPartyTests/CopyExecutorTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("CopyFile + CopyGlob executors")
struct CopyExecutorTests {
    private func makeTempTree() throws -> (src: URL, dst: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-copy-\(UUID().uuidString)")
        let src = root.appendingPathComponent("src")
        let dst = root.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        return (src, dst)
    }

    @Test("copyFile copies and reports dest path")
    func copyFileWorks() throws {
        let (src, dst) = try makeTempTree()
        try Data("hi".utf8).write(to: src.appendingPathComponent("a.js"))

        let record = try CopyFileExecutor.apply(
            .copyFile(from: "a.js", to: "a.js"),
            sourceDir: src, claudeDir: dst
        )
        #expect(record == ["a.js"])
        let content = try String(contentsOf: dst.appendingPathComponent("a.js"), encoding: .utf8)
        #expect(content == "hi")
    }

    @Test("copyGlob copies each *.ext match")
    func copyGlobWorks() throws {
        let (src, dst) = try makeTempTree()
        let srcHooks = src.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: srcHooks, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: srcHooks.appendingPathComponent("a.js"))
        try Data("2".utf8).write(to: srcHooks.appendingPathComponent("b.js"))
        try Data("x".utf8).write(to: srcHooks.appendingPathComponent("skip.md"))

        let record = try CopyGlobExecutor.apply(
            .copyGlob(from: "hooks/*.js", toDir: "hooks"),
            sourceDir: src, claudeDir: dst
        )
        #expect(Set(record) == Set(["hooks/a.js", "hooks/b.js"]))
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("hooks/a.js").path))
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("hooks/skip.md").path) == false)
    }

    @Test("copyGlob rejects non *.ext pattern")
    func copyGlobRejectsWeirdPattern() {
        let src = URL(fileURLWithPath: "/tmp")
        let dst = URL(fileURLWithPath: "/tmp")
        #expect(throws: ThirdPartyError.self) {
            _ = try CopyGlobExecutor.apply(
                .copyGlob(from: "**/*.js", toDir: "x"),
                sourceDir: src, claudeDir: dst
            )
        }
    }
}
```

- [ ] **Step 15.2: Run tests — expect failure**

Run: `swift test --filter CopyExecutorTests`
Expected: executors not defined.

- [ ] **Step 15.3: Implement protocol + executors**

Create `Sources/OrreryThirdParty/Steps/StepExecutor.swift`:

```swift
import Foundation
import OrreryCore

/// Each step type has its own executor (the project intentionally avoids a
/// single beastly `applyStep(_:)` switch). Executors are pure-ish: they touch
/// the filesystem but do not maintain internal state between calls.
enum StepExecutor {}
```

Create `Sources/OrreryThirdParty/Steps/CopyFileExecutor.swift`:

```swift
import Foundation
import OrreryCore

public enum CopyFileExecutor {
    /// Copies the file and returns its destination path relative to `claudeDir`.
    public static func apply(_ step: ThirdPartyStep,
                             sourceDir: URL, claudeDir: URL) throws -> [String] {
        guard case .copyFile(let from, let to) = step else {
            throw ThirdPartyError.stepFailed(reason: "not a copyFile step")
        }
        let src = sourceDir.appendingPathComponent(from)
        let dst = claudeDir.appendingPathComponent(to)
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: src, to: dst)
        return [to]
    }

    public static func rollback(paths: [String], claudeDir: URL) {
        let fm = FileManager.default
        for p in paths {
            try? fm.removeItem(at: claudeDir.appendingPathComponent(p))
        }
    }
}
```

Create `Sources/OrreryThirdParty/Steps/CopyGlobExecutor.swift`:

```swift
import Foundation
import OrreryCore

public enum CopyGlobExecutor {
    public static func apply(_ step: ThirdPartyStep,
                             sourceDir: URL, claudeDir: URL) throws -> [String] {
        guard case .copyGlob(let from, let toDir) = step else {
            throw ThirdPartyError.stepFailed(reason: "not a copyGlob step")
        }
        // v1 supports only the "<dir>/*.ext" shape used by cc-statusline.
        let parts = from.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts[1].hasPrefix("*.") else {
            throw ThirdPartyError.stepFailed(reason: "copyGlob only supports <dir>/*.ext patterns (got \(from))")
        }
        let srcSubdir = sourceDir.appendingPathComponent(parts[0])
        let ext = String(parts[1].dropFirst(2))
        let dstDir = claudeDir.appendingPathComponent(toDir)
        let fm = FileManager.default
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)

        var copied: [String] = []
        let contents = (try? fm.contentsOfDirectory(atPath: srcSubdir.path)) ?? []
        for name in contents where (name as NSString).pathExtension == ext {
            let src = srcSubdir.appendingPathComponent(name)
            let dst = dstDir.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
            copied.append("\(toDir)/\(name)")
        }
        return copied
    }

    public static func rollback(paths: [String], claudeDir: URL) {
        CopyFileExecutor.rollback(paths: paths, claudeDir: claudeDir)
    }
}
```

- [ ] **Step 15.4: Run tests — expect pass**

Run: `swift test --filter CopyExecutorTests`
Expected: 3 tests pass.

- [ ] **Step 15.5: Commit**

```bash
git add Sources/OrreryThirdParty/Steps Tests/OrreryThirdPartyTests/CopyExecutorTests.swift
git commit -m "[FEAT] CopyFile + CopyGlob executors with rollback"
```

---

## Task 16: Step executor — patchSettings

**Files:**
- Create: `Sources/OrreryThirdParty/Steps/PatchSettingsExecutor.swift`
- Create: `Tests/OrreryThirdPartyTests/PatchSettingsExecutorTests.swift`

- [ ] **Step 16.1: Write the failing tests**

Create `Tests/OrreryThirdPartyTests/PatchSettingsExecutorTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("PatchSettingsExecutor")
struct PatchSettingsExecutorTests {
    private func tempClaudeDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-patch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("missing file → writes new with full patch")
    func missingFileBootstrap() throws {
        let claudeDir = try tempClaudeDir()
        defer { try? FileManager.default.removeItem(at: claudeDir) }
        let patch: JSONValue = .object(["statusLine": .object(["type": .string("command")])])

        let record = try PatchSettingsExecutor.apply(
            .patchSettings(file: "settings.json", patch: patch),
            claudeDir: claudeDir,
            placeholders: [:]
        )
        #expect(record.file == "settings.json")
        let data = try Data(contentsOf: claudeDir.appendingPathComponent("settings.json"))
        let parsed = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(parsed == patch)
    }

    @Test("substitutes <CLAUDE_DIR> placeholder")
    func substitutesPlaceholder() throws {
        let claudeDir = try tempClaudeDir()
        defer { try? FileManager.default.removeItem(at: claudeDir) }
        let abs = claudeDir.path
        let patch: JSONValue = .object([
            "statusLine": .object(["command": .string("node <CLAUDE_DIR>/x.js")])
        ])
        _ = try PatchSettingsExecutor.apply(
            .patchSettings(file: "settings.json", patch: patch),
            claudeDir: claudeDir,
            placeholders: ["<CLAUDE_DIR>": abs]
        )
        let data = try Data(contentsOf: claudeDir.appendingPathComponent("settings.json"))
        let parsed = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let o) = parsed,
              case .object(let sl) = o["statusLine"],
              case .string(let cmd) = sl["command"] else {
            Issue.record("shape mismatch"); return
        }
        #expect(cmd == "node \(abs)/x.js")
    }

    @Test("rollback restores original bytes")
    func rollbackRestoresFile() throws {
        let claudeDir = try tempClaudeDir()
        defer { try? FileManager.default.removeItem(at: claudeDir) }
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        let original = Data(#"{"model":"old"}"#.utf8)
        try original.write(to: settingsURL)

        let patch: JSONValue = .object(["model": .string("new")])
        let record = try PatchSettingsExecutor.apply(
            .patchSettings(file: "settings.json", patch: patch),
            claudeDir: claudeDir,
            placeholders: [:]
        )
        try PatchSettingsExecutor.rollback(record: record, claudeDir: claudeDir)
        let afterRollback = try Data(contentsOf: settingsURL)
        let parsedOriginal = try JSONDecoder().decode(JSONValue.self, from: original)
        let parsedAfter = try JSONDecoder().decode(JSONValue.self, from: afterRollback)
        #expect(parsedOriginal == parsedAfter)
    }
}
```

- [ ] **Step 16.2: Run tests — expect failure**

Run: `swift test --filter PatchSettingsExecutorTests`
Expected: `PatchSettingsExecutor` not found.

- [ ] **Step 16.3: Implement the executor**

Create `Sources/OrreryThirdParty/Steps/PatchSettingsExecutor.swift`:

```swift
import Foundation
import OrreryCore

public enum PatchSettingsExecutor {
    public static func apply(_ step: ThirdPartyStep,
                             claudeDir: URL,
                             placeholders: [String: String]) throws -> SettingsPatchRecord {
        guard case .patchSettings(let file, let rawPatch) = step else {
            throw ThirdPartyError.stepFailed(reason: "not a patchSettings step")
        }
        let patch = substitute(rawPatch, placeholders: placeholders)
        let url = claudeDir.appendingPathComponent(file)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        var target: JSONValue
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            target = try JSONDecoder().decode(JSONValue.self, from: data)
        } else {
            target = .object([:])
        }

        let record = try SettingsJSONPatcher.apply(patch: patch, to: &target, file: file)
        try writeAtomically(value: target, to: url)
        return record
    }

    public static func rollback(record: SettingsPatchRecord, claudeDir: URL) throws {
        let url = claudeDir.appendingPathComponent(record.file)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        var target = try JSONDecoder().decode(JSONValue.self,
                                              from: Data(contentsOf: url))
        try SettingsJSONPatcher.unapply(record: record, to: &target)

        // If the result is {}, remove the file entirely so uninstall leaves
        // the env in its pre-install filesystem shape when we created it.
        if case .object(let o) = target, o.isEmpty {
            try? fm.removeItem(at: url)
            return
        }
        try writeAtomically(value: target, to: url)
    }

    // MARK: - Helpers

    private static func writeAtomically(value: JSONValue, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(value)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    /// Walks the JSON tree and replaces every occurrence of each placeholder
    /// key (e.g. `<CLAUDE_DIR>`) with the matching value inside *string* leaves.
    private static func substitute(_ value: JSONValue,
                                   placeholders: [String: String]) -> JSONValue {
        switch value {
        case .string(let s):
            var out = s
            for (k, v) in placeholders { out = out.replacingOccurrences(of: k, with: v) }
            return .string(out)
        case .array(let a):
            return .array(a.map { substitute($0, placeholders: placeholders) })
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, v) in o { out[k] = substitute(v, placeholders: placeholders) }
            return .object(out)
        default:
            return value
        }
    }
}
```

- [ ] **Step 16.4: Run tests — expect pass**

Run: `swift test --filter PatchSettingsExecutorTests`
Expected: 3 tests pass.

- [ ] **Step 16.5: Commit**

```bash
git add Sources/OrreryThirdParty/Steps/PatchSettingsExecutor.swift Tests/OrreryThirdPartyTests/PatchSettingsExecutorTests.swift
git commit -m "[FEAT] PatchSettingsExecutor with placeholder substitution + rollback"
```

---

## Task 17: `ManifestRunner` — install happy path + rollback

**Files:**
- Create: `Sources/OrreryThirdParty/ManifestRunner.swift`
- Create: `Tests/OrreryThirdPartyTests/ManifestRunnerInstallTests.swift`

- [ ] **Step 17.1: Write the failing test**

Create `Tests/OrreryThirdPartyTests/ManifestRunnerInstallTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("ManifestRunner — install")
struct ManifestRunnerInstallTests {
    private func setupFixture() throws -> (store: EnvironmentStore, envName: String, sourceDir: URL, runner: ManifestRunner) {
        // Build fake orrery home with a real env.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = EnvironmentStore(homeURL: home)
        let env = OrreryEnvironment(name: "dev")
        try store.save(env)
        try FileManager.default.createDirectory(
            at: store.toolConfigDir(tool: .claude, environment: "dev"),
            withIntermediateDirectories: true
        )

        // Vendored source tree with minimal cc-statusline-shaped content.
        let src = home.appendingPathComponent("src")
        let hooks = src.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try Data("// statusline".utf8).write(to: src.appendingPathComponent("statusline.js"))
        try Data("// tracker".utf8).write(to: hooks.appendingPathComponent("file-tracker.js"))

        let runner = ManifestRunner(store: store, fetcher: VendoredSource())
        return (store, "dev", src, runner)
    }

    @Test("install copies files, patches settings, writes lock file")
    func happyPath() throws {
        let (store, envName, srcDir, runner) = try setupFixture()
        let pkg = ThirdPartyPackage(
            id: "cc-statusline",
            displayName: "cc-statusline",
            description: "",
            source: .vendored(bundlePath: srcDir.path),
            steps: [
                .copyFile(from: "statusline.js", to: "statusline.js"),
                .copyGlob(from: "hooks/*.js", toDir: "hooks"),
                .patchSettings(file: "settings.json", patch: .object([
                    "statusLine": .object(["command": .string("node <CLAUDE_DIR>/statusline.js")])
                ]))
            ]
        )

        let record = try runner.install(pkg, into: envName,
                                        refOverride: nil, forceRefresh: false)
        #expect(record.packageID == "cc-statusline")
        #expect(record.copiedFiles.contains("statusline.js"))
        #expect(record.copiedFiles.contains("hooks/file-tracker.js"))

        let claudeDir = store.toolConfigDir(tool: .claude, environment: envName)
        #expect(FileManager.default.fileExists(
            atPath: claudeDir.appendingPathComponent("statusline.js").path))
        #expect(FileManager.default.fileExists(
            atPath: claudeDir.appendingPathComponent(".thirdparty/cc-statusline.lock.json").path))

        // Settings should contain the substituted command.
        let settings = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(contentsOf: claudeDir.appendingPathComponent("settings.json"))
        )
        guard case .object(let o) = settings,
              case .object(let sl) = o["statusLine"],
              case .string(let cmd) = sl["command"] else {
            Issue.record("shape mismatch"); return
        }
        #expect(cmd.hasPrefix("node \(claudeDir.path)/"))
    }
}
```

- [ ] **Step 17.2: Run test — expect failure**

Run: `swift test --filter ManifestRunnerInstallTests`
Expected: `ManifestRunner` not found.

- [ ] **Step 17.3: Implement `ManifestRunner` (install path only)**

Create `Sources/OrreryThirdParty/ManifestRunner.swift`:

```swift
import Foundation
import OrreryCore

public struct ManifestRunner: ThirdPartyRunner {
    private let store: EnvironmentStore
    private let fetcher: ThirdPartySourceFetcher

    public init(store: EnvironmentStore = .default,
                fetcher: ThirdPartySourceFetcher = GitSource()) {
        self.store = store
        self.fetcher = fetcher
    }

    public func install(_ pkg: ThirdPartyPackage,
                        into env: String,
                        refOverride: String?,
                        forceRefresh: Bool) throws -> InstallRecord {
        let claudeDir = try resolveClaudeDir(env: env)
        let lockURL = lockFileURL(claudeDir: claudeDir, packageID: pkg.id)

        // Task 19 adds: if lock exists → auto-uninstall.

        // Pre-check: `node` availability (non-fatal).
        warnIfMissingNode()

        // Fetch source.
        let cacheRoot = store.homeURL
            .appendingPathComponent("shared/thirdparty/cache")
        let (sourceDir, resolvedRef) = try fetcher.fetch(
            source: pkg.source, cacheRoot: cacheRoot,
            packageID: pkg.id, refOverride: refOverride,
            forceRefresh: forceRefresh)

        // Rollback bookkeeping.
        var copied: [String] = []
        var patched: [SettingsPatchRecord] = []

        do {
            for step in pkg.steps {
                switch step {
                case .copyFile:
                    copied.append(contentsOf: try CopyFileExecutor.apply(
                        step, sourceDir: sourceDir, claudeDir: claudeDir))
                case .copyGlob:
                    copied.append(contentsOf: try CopyGlobExecutor.apply(
                        step, sourceDir: sourceDir, claudeDir: claudeDir))
                case .patchSettings:
                    let rec = try PatchSettingsExecutor.apply(
                        step, claudeDir: claudeDir,
                        placeholders: ["<CLAUDE_DIR>": claudeDir.path])
                    patched.append(rec)
                }
            }
        } catch {
            // Reverse what succeeded.
            for rec in patched.reversed() {
                try? PatchSettingsExecutor.rollback(record: rec, claudeDir: claudeDir)
            }
            CopyFileExecutor.rollback(paths: copied, claudeDir: claudeDir)
            throw error
        }

        let manifestRef: String
        if case .git(_, let ref) = pkg.source { manifestRef = ref }
        else if case .vendored = pkg.source { manifestRef = "vendored" }
        else { manifestRef = "" }

        let record = InstallRecord(
            packageID: pkg.id,
            resolvedRef: resolvedRef,
            manifestRef: refOverride ?? manifestRef,
            installedAt: Date(),
            copiedFiles: copied,
            patchedSettings: patched
        )
        try writeLock(record, to: lockURL)
        return record
    }

    public func uninstall(packageID: String, from env: String) throws {
        fatalError("implemented in task 18")
    }

    public func listInstalled(in env: String) throws -> [InstallRecord] {
        fatalError("implemented in task 18")
    }

    // MARK: - Helpers

    private func resolveClaudeDir(env: String) throws -> URL {
        _ = try store.envDir(for: env) // validates existence; throws envNotFound otherwise
        return store.toolConfigDir(tool: .claude, environment: env)
    }

    private func lockFileURL(claudeDir: URL, packageID: String) -> URL {
        claudeDir.appendingPathComponent(".thirdparty/\(packageID).lock.json")
    }

    private func writeLock(_ record: InstallRecord, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    private func warnIfMissingNode() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["node"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            FileHandle.standardError.write(Data(
                "warning: `node` not found on PATH. cc-statusline needs Node.js to run.\n".utf8
            ))
        }
    }
}
```

- [ ] **Step 17.4: Run test — expect pass**

Run: `swift test --filter ManifestRunnerInstallTests`
Expected: happy-path install test passes.

- [ ] **Step 17.5: Commit**

```bash
git add Sources/OrreryThirdParty/ManifestRunner.swift Tests/OrreryThirdPartyTests/ManifestRunnerInstallTests.swift
git commit -m "[FEAT] ManifestRunner.install happy path + transactional rollback"
```

---

## Task 18: `ManifestRunner` — uninstall + list

**Files:**
- Modify: `Sources/OrreryThirdParty/ManifestRunner.swift`
- Create: `Tests/OrreryThirdPartyTests/ManifestRunnerUninstallTests.swift`

- [ ] **Step 18.1: Write the failing tests**

Create `Tests/OrreryThirdPartyTests/ManifestRunnerUninstallTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("ManifestRunner — uninstall")
struct ManifestRunnerUninstallTests {
    private struct Fixture {
        let store: EnvironmentStore
        let envName: String
        let sourceDir: URL
        let runner: ManifestRunner
        let pkg: ThirdPartyPackage
    }

    private func makeFixture() throws -> Fixture {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-runner-uninst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = EnvironmentStore(homeURL: home)
        try store.save(OrreryEnvironment(name: "dev"))
        try FileManager.default.createDirectory(
            at: store.toolConfigDir(tool: .claude, environment: "dev"),
            withIntermediateDirectories: true)

        let src = home.appendingPathComponent("src")
        try FileManager.default.createDirectory(
            at: src.appendingPathComponent("hooks"),
            withIntermediateDirectories: true)
        try Data("x".utf8).write(to: src.appendingPathComponent("statusline.js"))
        try Data("y".utf8).write(to: src.appendingPathComponent("hooks/a.js"))

        let pkg = ThirdPartyPackage(
            id: "cc-statusline",
            displayName: "cc-statusline",
            description: "",
            source: .vendored(bundlePath: src.path),
            steps: [
                .copyFile(from: "statusline.js", to: "statusline.js"),
                .copyGlob(from: "hooks/*.js", toDir: "hooks"),
                .patchSettings(file: "settings.json", patch: .object([
                    "statusLine": .object(["type": .string("command")])
                ])),
            ])
        return Fixture(store: store, envName: "dev",
                       sourceDir: src, runner: ManifestRunner(store: store, fetcher: VendoredSource()),
                       pkg: pkg)
    }

    @Test("uninstall removes copied files, reverses settings, deletes lock")
    func uninstallRoundTrips() throws {
        let f = try makeFixture()
        _ = try f.runner.install(f.pkg, into: f.envName,
                                 refOverride: nil, forceRefresh: false)
        try f.runner.uninstall(packageID: "cc-statusline", from: f.envName)

        let claudeDir = f.store.toolConfigDir(tool: .claude, environment: f.envName)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: claudeDir.appendingPathComponent("statusline.js").path) == false)
        #expect(fm.fileExists(atPath: claudeDir.appendingPathComponent("hooks/a.js").path) == false)
        #expect(fm.fileExists(atPath: claudeDir.appendingPathComponent(".thirdparty/cc-statusline.lock.json").path) == false)
        // settings.json should be gone because it was empty after rollback.
        #expect(fm.fileExists(atPath: claudeDir.appendingPathComponent("settings.json").path) == false)
    }

    @Test("uninstall when not installed throws notInstalled")
    func uninstallNotInstalled() throws {
        let f = try makeFixture()
        #expect(throws: ThirdPartyError.self) {
            try f.runner.uninstall(packageID: "cc-statusline", from: f.envName)
        }
    }

    @Test("listInstalled returns one record after install")
    func listAfterInstall() throws {
        let f = try makeFixture()
        _ = try f.runner.install(f.pkg, into: f.envName,
                                 refOverride: nil, forceRefresh: false)
        let records = try f.runner.listInstalled(in: f.envName)
        #expect(records.count == 1)
        #expect(records[0].packageID == "cc-statusline")
    }
}
```

- [ ] **Step 18.2: Run tests — expect failure**

Run: `swift test --filter ManifestRunnerUninstallTests`
Expected: fatalError stops on uninstall / list.

- [ ] **Step 18.3: Implement uninstall + list**

In `ManifestRunner.swift`, replace the two `fatalError` stubs with:

```swift
    public func uninstall(packageID: String, from env: String) throws {
        let claudeDir = try resolveClaudeDir(env: env)
        let lockURL = lockFileURL(claudeDir: claudeDir, packageID: packageID)
        let fm = FileManager.default
        guard fm.fileExists(atPath: lockURL.path) else {
            throw ThirdPartyError.notInstalled(id: packageID)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(InstallRecord.self,
                                        from: Data(contentsOf: lockURL))

        for patchRec in record.patchedSettings.reversed() {
            try? PatchSettingsExecutor.rollback(record: patchRec, claudeDir: claudeDir)
        }
        for p in record.copiedFiles {
            try? fm.removeItem(at: claudeDir.appendingPathComponent(p))
        }
        try? fm.removeItem(at: lockURL)
        // Remove the .thirdparty dir if it's now empty.
        let thirdDir = claudeDir.appendingPathComponent(".thirdparty")
        if let contents = try? fm.contentsOfDirectory(atPath: thirdDir.path),
           contents.isEmpty {
            try? fm.removeItem(at: thirdDir)
        }
    }

    public func listInstalled(in env: String) throws -> [InstallRecord] {
        let claudeDir = try resolveClaudeDir(env: env)
        let thirdDir = claudeDir.appendingPathComponent(".thirdparty")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: thirdDir.path) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return entries.compactMap { name in
            guard name.hasSuffix(".lock.json") else { return nil }
            let url = thirdDir.appendingPathComponent(name)
            return try? decoder.decode(InstallRecord.self,
                                       from: Data(contentsOf: url))
        }
    }
```

- [ ] **Step 18.4: Run tests — expect pass**

Run: `swift test --filter ManifestRunnerUninstallTests`
Expected: 3 tests pass.

- [ ] **Step 18.5: Commit**

```bash
git add Sources/OrreryThirdParty/ManifestRunner.swift Tests/OrreryThirdPartyTests/ManifestRunnerUninstallTests.swift
git commit -m "[FEAT] ManifestRunner: uninstall + list"
```

---

## Task 19: `ManifestRunner` — reinstall auto-uninstalls

**Files:**
- Modify: `Sources/OrreryThirdParty/ManifestRunner.swift`
- Create: `Tests/OrreryThirdPartyTests/ManifestRunnerReinstallTests.swift`

- [ ] **Step 19.1: Write the failing test**

Create `Tests/OrreryThirdPartyTests/ManifestRunnerReinstallTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("ManifestRunner — reinstall")
struct ManifestRunnerReinstallTests {
    @Test("installing over an existing lock first uninstalls, then reinstalls")
    func reinstallAutoUninstalls() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-reinst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = EnvironmentStore(homeURL: home)
        try store.save(OrreryEnvironment(name: "dev"))
        try FileManager.default.createDirectory(
            at: store.toolConfigDir(tool: .claude, environment: "dev"),
            withIntermediateDirectories: true)
        let src = home.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("v1".utf8).write(to: src.appendingPathComponent("statusline.js"))
        let pkg = ThirdPartyPackage(
            id: "cc-statusline", displayName: "cc", description: "",
            source: .vendored(bundlePath: src.path),
            steps: [.copyFile(from: "statusline.js", to: "statusline.js")]
        )
        let runner = ManifestRunner(store: store, fetcher: VendoredSource())
        _ = try runner.install(pkg, into: "dev", refOverride: nil, forceRefresh: false)

        // Mutate the source so we can tell v2 from v1.
        try Data("v2".utf8).write(to: src.appendingPathComponent("statusline.js"))
        _ = try runner.install(pkg, into: "dev", refOverride: nil, forceRefresh: false)

        let claudeDir = store.toolConfigDir(tool: .claude, environment: "dev")
        let content = try String(contentsOf: claudeDir.appendingPathComponent("statusline.js"),
                                 encoding: .utf8)
        #expect(content == "v2")
        let records = try runner.listInstalled(in: "dev")
        #expect(records.count == 1) // not double-written
    }
}
```

- [ ] **Step 19.2: Run test — expect failure**

Run: `swift test --filter ManifestRunnerReinstallTests`
Expected: second `install` throws because copyFile path collides, or lock-file double-write assertion fails.

- [ ] **Step 19.3: Add auto-uninstall branch**

Near the top of `install(...)` in `ManifestRunner.swift`, insert right after `resolveClaudeDir`:

```swift
        // Already installed? Reinstall = uninstall + install (spec decision 7c-B).
        if FileManager.default.fileExists(atPath: lockURL.path) {
            FileHandle.standardError.write(Data(
                "\(pkg.id) already installed — reinstalling.\n".utf8))
            try uninstall(packageID: pkg.id, from: env)
        }
```

- [ ] **Step 19.4: Run all runner tests — expect pass**

Run: `swift test --filter ManifestRunner`
Expected: all runner tests from tasks 17, 18, 19 pass.

- [ ] **Step 19.5: Commit**

```bash
git add Sources/OrreryThirdParty/ManifestRunner.swift Tests/OrreryThirdPartyTests/ManifestRunnerReinstallTests.swift
git commit -m "[FEAT] ManifestRunner: reinstall auto-uninstalls first"
```

---

## Task 20: Integration test — end-to-end install/uninstall via VendoredSource

**Files:**
- Create: `Tests/OrreryThirdPartyTests/EndToEndTests.swift`

- [ ] **Step 20.1: Write integration test**

Create `Tests/OrreryThirdPartyTests/EndToEndTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("End-to-end — vendored source")
struct EndToEndTests {
    @Test("full install then uninstall leaves env byte-equivalent (empty)")
    func fullRoundTrip() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = EnvironmentStore(homeURL: home)
        try store.save(OrreryEnvironment(name: "dev"))
        let claudeDir = store.toolConfigDir(tool: .claude, environment: "dev")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        // Snapshot the pre-install tree (paths only — contents aren't on disk yet).
        let before = snapshot(at: claudeDir)

        // Vendored tree mirroring cc-statusline's file shape.
        let src = home.appendingPathComponent("src")
        let hooks = src.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try Data("statusline".utf8).write(to: src.appendingPathComponent("statusline.js"))
        for name in ["message-tracker.js", "summary-updater.js", "file-tracker.js"] {
            try Data(name.utf8).write(to: hooks.appendingPathComponent(name))
        }

        // Use the real cc-statusline manifest but switch source to vendored.
        var pkg = try BuiltInRegistry().lookup("cc-statusline")
        pkg = ThirdPartyPackage(
            id: pkg.id, displayName: pkg.displayName,
            description: pkg.description,
            source: .vendored(bundlePath: src.path),
            steps: pkg.steps)

        let runner = ManifestRunner(store: store, fetcher: VendoredSource())
        _ = try runner.install(pkg, into: "dev",
                               refOverride: nil, forceRefresh: false)
        try runner.uninstall(packageID: "cc-statusline", from: "dev")

        let after = snapshot(at: claudeDir)
        #expect(after == before)
    }

    private func snapshot(at url: URL) -> Set<String> {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return []
        }
        var result = Set<String>()
        for case let file as URL in en {
            result.insert(file.path.replacingOccurrences(of: url.path, with: ""))
        }
        return result
    }
}
```

- [ ] **Step 20.2: Run the test**

Run: `swift test --filter EndToEndTests`
Expected: passes — the post-uninstall claude dir is empty again.

- [ ] **Step 20.3: Commit**

```bash
git add Tests/OrreryThirdPartyTests/EndToEndTests.swift
git commit -m "[TEST] end-to-end install/uninstall round-trip via VendoredSource"
```

---

## Task 21: L10n strings for `thirdparty` command

**Files:**
- Modify: `Sources/OrreryCore/Resources/Localization/en.json`
- Modify: `Sources/OrreryCore/Resources/Localization/zh-Hant.json`
- Modify: `Sources/OrreryCore/Resources/Localization/ja.json`
- Modify: `Sources/OrreryCore/Resources/Localization/l10n-signatures.json`

- [ ] **Step 21.1: Add English strings**

Append to `en.json` (inside the outer `{}`) — the exact keys the command file uses:

```json
  "thirdparty.abstract": "Install, uninstall, and list third-party add-ons for an environment",
  "thirdparty.install.abstract": "Install a third-party add-on into an environment",
  "thirdparty.install.idHelp": "Package id (e.g. cc-statusline)",
  "thirdparty.install.envHelp": "Target environment name",
  "thirdparty.install.refHelp": "Override the manifest source ref (git branch/tag/sha)",
  "thirdparty.install.forceRefreshHelp": "Re-clone the source even if the cached copy already exists",
  "thirdparty.install.success": "Installed {id} ({shortRef}) into env '{env}'. {fileCount} files copied, settings patched.",
  "thirdparty.install.reinstallNotice": "{id} already installed in '{env}' — reinstalling.",
  "thirdparty.uninstall.abstract": "Remove a third-party add-on from an environment",
  "thirdparty.uninstall.success": "Removed {id} from env '{env}'.",
  "thirdparty.list.abstract": "List installed third-party add-ons for an environment",
  "thirdparty.list.none": "No third-party add-ons installed in '{env}'.",
  "thirdparty.list.item": "  {id}  {shortRef}  installed {date}",
  "thirdparty.available.abstract": "List third-party add-ons shipped with orrery",
```

- [ ] **Step 21.2: Mirror into other locales**

Copy the same keys into `zh-Hant.json` with Traditional Chinese translations:

```json
  "thirdparty.abstract": "安裝、移除、列出環境的第三方外掛",
  "thirdparty.install.abstract": "把第三方外掛安裝到指定環境",
  "thirdparty.install.idHelp": "套件 id（例如 cc-statusline）",
  "thirdparty.install.envHelp": "目標環境名稱",
  "thirdparty.install.refHelp": "覆寫 manifest 的來源 ref（git branch/tag/sha）",
  "thirdparty.install.forceRefreshHelp": "即使 cache 已存在也強制重新 clone",
  "thirdparty.install.success": "已將 {id}（{shortRef}）安裝到環境 '{env}'，複製 {fileCount} 個檔案並更新 settings。",
  "thirdparty.install.reinstallNotice": "'{env}' 已安裝 {id}，將先移除再重新安裝。",
  "thirdparty.uninstall.abstract": "從環境移除第三方外掛",
  "thirdparty.uninstall.success": "已從環境 '{env}' 移除 {id}。",
  "thirdparty.list.abstract": "列出環境安裝的第三方外掛",
  "thirdparty.list.none": "'{env}' 沒有安裝任何第三方外掛。",
  "thirdparty.list.item": "  {id}  {shortRef}  安裝於 {date}",
  "thirdparty.available.abstract": "列出 orrery 內建支援的第三方外掛",
```

For `ja.json`, copy the English strings verbatim (they are stubbed per the
localization README — translator will fill in later).

- [ ] **Step 21.3: Add signatures**

Read `l10n-signatures.json` to learn the existing entry format, then add one entry per new key. Example for `thirdparty.install.success` (four `{...}` placeholders → parameters `id`, `shortRef`, `fileCount`, `env`):

```json
  "thirdparty.install.success": {
    "kind": "format",
    "params": [
      { "label": "_", "name": "id", "type": "String" },
      { "label": "_", "name": "shortRef", "type": "String" },
      { "label": "_", "name": "fileCount", "type": "Int" },
      { "label": "_", "name": "env", "type": "String" }
    ]
  },
```

Follow the same shape for every new key. Keys with no placeholders are plain constants (`{ "kind": "constant" }`). The `l10n-signatures.json` determines the generated Swift API; the codegen plugin reads it during build.

- [ ] **Step 21.4: Build to verify L10n codegen passes**

Run: `swift build`
Expected: build succeeds, generated `L10n.Thirdparty.*` accessors available.

- [ ] **Step 21.5: Commit**

```bash
git add Sources/OrreryCore/Resources/Localization/en.json Sources/OrreryCore/Resources/Localization/zh-Hant.json Sources/OrreryCore/Resources/Localization/ja.json Sources/OrreryCore/Resources/Localization/l10n-signatures.json
git commit -m "[I18N] add thirdparty command strings"
```

---

## Task 22: `ThirdPartyCommand` CLI surface

**Files:**
- Create: `Sources/OrreryCore/Commands/ThirdPartyCommand.swift`
- Modify: `Sources/OrreryCore/Commands/OrreryCommand.swift`
- Modify: `Sources/OrreryThirdParty/OrreryThirdPartyRuntime.swift`
- Modify: `Sources/orrery/main.swift`

- [ ] **Step 22.1: Create the command**

Create `Sources/OrreryCore/Commands/ThirdPartyCommand.swift`:

```swift
import ArgumentParser
import Foundation

public struct ThirdPartyCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "thirdparty",
        abstract: L10n.Thirdparty.abstract,
        subcommands: [Install.self, Uninstall.self, List.self, Available.self]
    )
    public init() {}

    public struct Install: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: L10n.Thirdparty.Install.abstract
        )

        @Argument(help: ArgumentHelp(L10n.Thirdparty.Install.idHelp))
        public var id: String

        @Option(name: .long, help: ArgumentHelp(L10n.Thirdparty.Install.envHelp))
        public var env: String

        @Option(name: .long, help: ArgumentHelp(L10n.Thirdparty.Install.refHelp))
        public var ref: String?

        @Flag(name: .long, help: ArgumentHelp(L10n.Thirdparty.Install.forceRefreshHelp))
        public var forceRefresh: Bool = false

        public init() {}

        public func run() throws {
            let registry = try ThirdPartyRuntime.registry()
            let runner = try ThirdPartyRuntime.runner()
            let pkg = try registry.lookup(id)
            let record = try runner.install(pkg, into: env,
                                            refOverride: ref, forceRefresh: forceRefresh)
            print(L10n.Thirdparty.Install.success(
                record.packageID,
                String(record.resolvedRef.prefix(7)),
                record.copiedFiles.count,
                env
            ))
        }
    }

    public struct Uninstall: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "uninstall",
            abstract: L10n.Thirdparty.Uninstall.abstract
        )

        @Argument(help: ArgumentHelp(L10n.Thirdparty.Install.idHelp))
        public var id: String

        @Option(name: .long, help: ArgumentHelp(L10n.Thirdparty.Install.envHelp))
        public var env: String

        public init() {}

        public func run() throws {
            let runner = try ThirdPartyRuntime.runner()
            try runner.uninstall(packageID: id, from: env)
            print(L10n.Thirdparty.Uninstall.success(id, env))
        }
    }

    public struct List: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: L10n.Thirdparty.List.abstract
        )

        @Option(name: .long, help: ArgumentHelp(L10n.Thirdparty.Install.envHelp))
        public var env: String

        public init() {}

        public func run() throws {
            let runner = try ThirdPartyRuntime.runner()
            let records = try runner.listInstalled(in: env)
            if records.isEmpty {
                print(L10n.Thirdparty.List.none(env))
                return
            }
            let fmt = ISO8601DateFormatter()
            for r in records {
                print(L10n.Thirdparty.List.item(
                    r.packageID, String(r.resolvedRef.prefix(7)),
                    fmt.string(from: r.installedAt)))
            }
        }
    }

    public struct Available: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "available",
            abstract: L10n.Thirdparty.Available.abstract
        )
        public init() {}
        public func run() throws {
            let registry = try ThirdPartyRuntime.registry()
            for id in registry.listAvailable() { print(id) }
        }
    }
}
```

- [ ] **Step 22.2: Register subcommand in `OrreryCommand`**

Edit `Sources/OrreryCore/Commands/OrreryCommand.swift` — add `ThirdPartyCommand.self` to the `subcommands:` list (alongside the existing entries).

- [ ] **Step 22.3: Fill in the thirdparty runtime registration**

Replace `Sources/OrreryThirdParty/OrreryThirdPartyRuntime.swift` with:

```swift
import Foundation
import OrreryCore

public enum OrreryThirdPartyRuntime {
    public static func register() {
        ThirdPartyRuntime.makeRunner = { ManifestRunner() }
        ThirdPartyRuntime.makeRegistry = { BuiltInRegistry() }
    }
}
```

- [ ] **Step 22.4: Wire the binary**

Modify `Sources/orrery/main.swift`:

```swift
import Foundation
import OrreryCore
import OrreryThirdParty

LegacyOrbitalMigration.runIfNeeded()
OriginTakeoverBootstrap.runIfNeeded()
OrreryThirdPartyRuntime.register()
OrreryCommand.main()
```

- [ ] **Step 22.5: Build + smoke test**

Run: `swift build && .build/debug/orrery-bin thirdparty available`
Expected: prints `cc-statusline` and exits.

Run: `swift build && .build/debug/orrery-bin thirdparty --help`
Expected: help text with four subcommands.

- [ ] **Step 22.6: Commit**

```bash
git add Sources/OrreryCore/Commands/ThirdPartyCommand.swift Sources/OrreryCore/Commands/OrreryCommand.swift Sources/OrreryThirdParty/OrreryThirdPartyRuntime.swift Sources/orrery/main.swift
git commit -m "[FEAT] orrery thirdparty install/uninstall/list/available command"
```

---

## Task 23: Network smoke test (opt-in via env var)

**Files:**
- Create: `Tests/OrreryThirdPartyTests/GitSourceSmokeTests.swift`

- [ ] **Step 23.1: Write the gated test**

Create `Tests/OrreryThirdPartyTests/GitSourceSmokeTests.swift`:

```swift
import Testing
import Foundation
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("GitSource — network smoke (opt-in)",
       .enabled(if: ProcessInfo.processInfo.environment["ORRERY_NETWORK_TESTS"] == "1"))
struct GitSourceSmokeTests {
    @Test("clones cc-statusline main and finds statusline.js")
    func realClone() throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-git-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let (dir, sha) = try GitSource().fetch(
            source: .git(url: "https://github.com/NYCU-Chung/cc-statusline",
                         ref: "main"),
            cacheRoot: cacheRoot,
            packageID: "cc-statusline",
            refOverride: nil,
            forceRefresh: false
        )
        #expect(sha.count == 40)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("statusline.js").path))
    }
}
```

- [ ] **Step 23.2: Run without the env var (test is skipped)**

Run: `swift test --filter GitSourceSmokeTests`
Expected: 0 tests executed (suite disabled).

- [ ] **Step 23.3: Run with the env var (optional, local dev only)**

Run: `ORRERY_NETWORK_TESTS=1 swift test --filter GitSourceSmokeTests`
Expected: test passes — real clone lands `statusline.js` into cache.

- [ ] **Step 23.4: Commit**

```bash
git add Tests/OrreryThirdPartyTests/GitSourceSmokeTests.swift
git commit -m "[TEST] GitSource network smoke test (opt-in via ORRERY_NETWORK_TESTS=1)"
```

---

## Self-Review

### Spec coverage

| Spec section | Task(s) |
|---|---|
| Package layout | 1 |
| Core protocol surface (`ThirdPartyPackage`/`Source`/`Step`/protocols) | 3, 5 |
| `InstallRecord` + `SettingsPatchRecord` | 4 |
| `JSONValue` | 2 |
| Manifest schema + parsing | 11, 12 |
| Bundled `cc-statusline` manifest | 12 |
| `<CLAUDE_DIR>` install-time substitution | 16 |
| Merge semantics (scalar/object/array) | 6, 7, 8 |
| Hook-matcher comparator | 9 |
| Shared cache (`~/.orrery/shared/thirdparty/cache/<id>/@<sha>/`) | 13, 17 |
| Per-env lock file (`<env>/claude/.thirdparty/<id>.lock.json`) | 17 |
| CLI surface (`install`/`uninstall`/`list`/`available`) | 22 |
| Install flow (ref resolve, cache, transactional rollback, lock write) | 13, 15, 16, 17 |
| Uninstall flow (reverse patches, remove files, delete lock, leave cache) | 16, 18 |
| Auto re-install on existing lock | 19 |
| `node` missing warning | 17 |
| Unit tests — `SettingsJSONPatcher` | 6–10 |
| Unit tests — `ManifestParser` | 11 |
| Unit tests — `BuiltInRegistry` | 12 |
| Unit tests — `InstallRecord` codec | 4 |
| Integration — full vendored round-trip | 20 |
| Integration — real git clone smoke | 23 |
| L10n | 21 |

### Placeholder check

Scanned for "TBD", "TODO", "implement later", "handle edge cases", "similar to task". None present. All code steps contain complete bodies. Task 14 has no TDD test because it is structurally trivial (30-line fetcher exercised by task 20's end-to-end test) and splitting it would be ceremony without value.

### Type consistency

- `ThirdPartyPackage`, `ThirdPartySource`, `ThirdPartyStep` defined in task 3, referenced identically in 11–22.
- `InstallRecord`, `SettingsPatchRecord`, `BeforeState` defined in task 4, used unchanged in 17–19.
- `ThirdPartyRunner`/`ThirdPartyRegistry` defined in task 5, implemented in 12 (`BuiltInRegistry`) and 17 (`ManifestRunner`).
- `ThirdPartySourceFetcher` defined in task 13, implemented in 13 (`GitSource`) and 14 (`VendoredSource`).
- `SettingsJSONPatcher.apply(patch:to:file:)` signature stays identical across 6–10.
- CLI uses `L10n.Thirdparty.*` accessors whose keys are all introduced in task 21.

No renames or signature drift detected.
