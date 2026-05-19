# Account Pool 從 Env 拆分 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 AI 工具帳號從 env 中拆出，成為跨 env 共用的 accounts pool；新使用者可不接觸 env 概念，直接用 `orrery account` 切帳號。

**Architecture:** 新增 `AccountStore` 管理 `~/.orrery/accounts/{tool}/<id>/` 池；env.json 改用 id 引用 account；`CredentialAdapter` protocol 抽象「啟動時讓憑證對工具可見」的行為（檔案型用 symlink、macOS Claude 用 Keychain 複寫）。首次跑新版自動從現有 env 遷移憑證進池子。

**Tech Stack:** Swift 6, swift-testing (`@Suite`/`@Test`/`#expect`), ArgumentParser, FileManager, macOS `security` CLI（透過既有 `ClaudeKeychain` wrapper）。

**Spec:** `docs/superpowers/specs/2026-05-19-account-env-separation-design.md`

---

## File Structure

### Created

| Path | Responsibility |
|------|----------------|
| `Sources/OrreryCore/Models/Account.swift` | `Account` struct, `AccountID` typealias |
| `Sources/OrreryCore/Storage/AccountStore.swift` | Accounts pool CRUD、reference scanning |
| `Sources/OrreryCore/Setup/CredentialAdapter.swift` | `CredentialAdapter` protocol、`adapterFor(tool:)` factory |
| `Sources/OrreryCore/Setup/FilesystemCredentialAdapter.swift` | Codex/Gemini/Linux Claude symlink 實作 |
| `Sources/OrreryCore/Setup/KeychainCredentialAdapter.swift` | macOS Claude metadata-pointer 實作 |
| `Sources/OrreryCore/Commands/AccountCommand.swift` | Root `orrery account` 命令 + subcommand 註冊 |
| `Sources/OrreryCore/Commands/AccountAddCommand.swift` | `orrery account add` |
| `Sources/OrreryCore/Commands/AccountListCommand.swift` | `orrery account list` |
| `Sources/OrreryCore/Commands/AccountShowCommand.swift` | `orrery account show` |
| `Sources/OrreryCore/Commands/AccountUseCommand.swift` | `orrery account use` |
| `Sources/OrreryCore/Commands/AccountRemoveCommand.swift` | `orrery account remove` |
| `Sources/OrreryCore/Setup/AccountMigration.swift` | v2→v3 一次性自動遷移 |
| `Tests/OrreryTests/AccountStoreTests.swift` | AccountStore unit tests |
| `Tests/OrreryTests/CredentialAdapterTests.swift` | Adapter tests（含 macOS conditional） |
| `Tests/OrreryTests/AccountCommandsTests.swift` | CLI subcommand tests |
| `Tests/OrreryTests/AccountMigrationTests.swift` | 遷移流程 tests |

### Modified

| Path | 變更內容 |
|------|---------|
| `Sources/OrreryCore/Models/OrreryEnvironment.swift` | 新增 `accounts: [Tool: String]` 欄位（Codable 自動處理） |
| `Sources/OrreryCore/Storage/EnvironmentStore.swift` | 新增 account 引用解析 helper、refs scanner |
| `Sources/OrreryCore/Commands/RunCommand.swift` | exec 前呼叫 `CredentialAdapter.materialize(env:account:)` |
| `Sources/OrreryCore/Commands/PhantomCommand.swift` | 新增 `account` 子命令 |
| `Sources/OrreryCore/Commands/OrreryCommand.swift` | 註冊 `AccountCommand`、version bump |
| `Sources/OrreryCore/MCP/MCPServer.swift` | currentVersion bump |
| `Sources/OrreryCore/Version.swift` | Bump |
| `Sources/OrreryCore/Resources/Localization/{en,zh-Hant,ja}.json` | 新增 account 系列字串 |
| `CHANGELOG.md` | 加入 release note |
| `docs/index.html` / `docs/zh_TW.html` | 版本 badge |

---

## Task 1: Account model

**Files:**
- Create: `Sources/OrreryCore/Models/Account.swift`
- Test: `Tests/OrreryTests/AccountStoreTests.swift`（本任務只用到 Account model 部分）

- [ ] **Step 1: Write the failing test**

新建 `Tests/OrreryTests/AccountStoreTests.swift`：

```swift
import Testing
import Foundation
@testable import OrreryCore

@Suite("Account model")
struct AccountModelTests {
    @Test("encodes and decodes with iso8601 dates")
    func roundTrip() throws {
        let account = Account(
            id: "550e8400-e29b-41d4-a716-446655440000",
            tool: .claude,
            displayName: "work",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            keychainItem: "Claude Code-orrery-550e8400"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(account)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Account.self, from: data)

        #expect(decoded.id == account.id)
        #expect(decoded.tool == .claude)
        #expect(decoded.displayName == "work")
        #expect(decoded.keychainItem == "Claude Code-orrery-550e8400")
    }

    @Test("keychainItem optional for non-macOS-claude accounts")
    func keychainItemOptional() throws {
        let account = Account(
            id: UUID().uuidString,
            tool: .codex,
            displayName: "personal",
            createdAt: Date()
        )
        #expect(account.keychainItem == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AccountModelTests`
Expected: FAIL — `cannot find 'Account' in scope`

- [ ] **Step 3: Create the Account model**

新建 `Sources/OrreryCore/Models/Account.swift`：

```swift
import Foundation

public typealias AccountID = String

/// 跨 env 共用的工具憑證 pool 中的一筆。
/// 持久化於 `~/.orrery/accounts/<tool>/<id>/metadata.json`。
public struct Account: Codable, Sendable, Equatable {
    public var id: AccountID
    public var tool: Tool
    public var displayName: String
    public var createdAt: Date

    /// macOS Claude 專用：對應的 Keychain item 名稱。
    /// 其他工具 / 平台組合為 nil。
    public var keychainItem: String?

    public init(
        id: AccountID = UUID().uuidString,
        tool: Tool,
        displayName: String,
        createdAt: Date = Date(),
        keychainItem: String? = nil
    ) {
        self.id = id
        self.tool = tool
        self.displayName = displayName
        self.createdAt = createdAt
        self.keychainItem = keychainItem
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AccountModelTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Models/Account.swift Tests/OrreryTests/AccountStoreTests.swift
git commit -m "[ADD] Account model: tool-scoped credential pool entry"
```

---

## Task 2: AccountStore CRUD

**Files:**
- Create: `Sources/OrreryCore/Storage/AccountStore.swift`
- Modify: `Tests/OrreryTests/AccountStoreTests.swift`

- [ ] **Step 1: Add failing tests for AccountStore**

在 `Tests/OrreryTests/AccountStoreTests.swift` 加入下列 suite：

```swift
@Suite("AccountStore")
struct AccountStoreTests {
    var tmpDir: URL!
    var store: AccountStore!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-acct-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = AccountStore(homeURL: tmpDir)
    }

    @Test("save creates accounts/<tool>/<id>/metadata.json")
    func saveCreatesFile() throws {
        let account = Account(tool: .claude, displayName: "work")
        try store.save(account)

        let path = tmpDir
            .appendingPathComponent("accounts/claude/\(account.id)/metadata.json")
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    @Test("load returns saved account")
    func loadReturnsSaved() throws {
        let original = Account(tool: .codex, displayName: "personal")
        try store.save(original)
        let loaded = try store.load(id: original.id, tool: .codex)
        #expect(loaded.displayName == "personal")
    }

    @Test("load throws when id missing")
    func loadMissing() throws {
        #expect(throws: AccountStore.Error.self) {
            try store.load(id: "nonexistent", tool: .claude)
        }
    }

    @Test("list returns all accounts for a tool")
    func listByTool() throws {
        try store.save(Account(tool: .claude, displayName: "work"))
        try store.save(Account(tool: .claude, displayName: "personal"))
        try store.save(Account(tool: .codex, displayName: "work"))

        let claudeAccounts = try store.list(tool: .claude)
        #expect(claudeAccounts.count == 2)
        #expect(Set(claudeAccounts.map(\.displayName)) == ["work", "personal"])
    }

    @Test("listAll groups by tool")
    func listAll() throws {
        try store.save(Account(tool: .claude, displayName: "a"))
        try store.save(Account(tool: .gemini, displayName: "b"))
        let all = try store.listAll()
        #expect(all[.claude]?.count == 1)
        #expect(all[.gemini]?.count == 1)
        #expect(all[.codex] == nil || all[.codex]?.isEmpty == true)
    }

    @Test("delete removes account dir")
    func deleteRemovesDir() throws {
        let account = Account(tool: .claude, displayName: "old")
        try store.save(account)
        try store.delete(id: account.id, tool: .claude)
        #expect(throws: AccountStore.Error.self) {
            try store.load(id: account.id, tool: .claude)
        }
    }

    @Test("findByDisplayName matches case-sensitively")
    func findByDisplayName() throws {
        let acct = Account(tool: .claude, displayName: "Work")
        try store.save(acct)
        #expect(try store.findByDisplayName("Work", tool: .claude)?.id == acct.id)
        #expect(try store.findByDisplayName("work", tool: .claude) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AccountStoreTests`
Expected: FAIL — `cannot find 'AccountStore' in scope`

- [ ] **Step 3: Implement AccountStore**

新建 `Sources/OrreryCore/Storage/AccountStore.swift`：

```swift
import Foundation

public struct AccountStore: Sendable {
    public enum Error: Swift.Error {
        case accountNotFound(id: String, tool: Tool)
        case invalidAccountName(String)
    }

    public let homeURL: URL
    private let fm = FileManager.default

    public init(homeURL: URL) {
        self.homeURL = homeURL
    }

    public static var `default`: AccountStore {
        AccountStore(homeURL: EnvironmentStore.default.homeURL)
    }

    // MARK: - Paths

    public func accountsRoot() -> URL {
        homeURL.appendingPathComponent("accounts")
    }

    public func toolDir(_ tool: Tool) -> URL {
        accountsRoot().appendingPathComponent(tool.rawValue)
    }

    public func accountDir(id: AccountID, tool: Tool) -> URL {
        toolDir(tool).appendingPathComponent(id)
    }

    private func metadataURL(id: AccountID, tool: Tool) -> URL {
        accountDir(id: id, tool: tool).appendingPathComponent("metadata.json")
    }

    // MARK: - CRUD

    public func save(_ account: Account) throws {
        let dir = accountDir(id: account.id, tool: account.tool)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(account)
        try data.write(to: metadataURL(id: account.id, tool: account.tool), options: .atomic)
    }

    public func load(id: AccountID, tool: Tool) throws -> Account {
        let url = metadataURL(id: id, tool: tool)
        guard fm.fileExists(atPath: url.path) else {
            throw Error.accountNotFound(id: id, tool: tool)
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Account.self, from: data)
    }

    public func list(tool: Tool) throws -> [Account] {
        let dir = toolDir(tool)
        guard fm.fileExists(atPath: dir.path) else { return [] }
        let ids = try fm.contentsOfDirectory(atPath: dir.path)
        return ids.compactMap { try? load(id: $0, tool: tool) }
            .sorted { $0.displayName < $1.displayName }
    }

    public func listAll() throws -> [Tool: [Account]] {
        var result: [Tool: [Account]] = [:]
        for tool in Tool.allCases {
            let accts = try list(tool: tool)
            if !accts.isEmpty {
                result[tool] = accts
            }
        }
        return result
    }

    public func delete(id: AccountID, tool: Tool) throws {
        let dir = accountDir(id: id, tool: tool)
        guard fm.fileExists(atPath: dir.path) else {
            throw Error.accountNotFound(id: id, tool: tool)
        }
        try fm.removeItem(at: dir)
    }

    public func findByDisplayName(_ name: String, tool: Tool) throws -> Account? {
        try list(tool: tool).first { $0.displayName == name }
    }
}
```

> 假設 `Tool` 已是 `CaseIterable`。如果不是，在這個 task 順手加（先查 Sources/OrreryCore/Models/Tool.swift 是否已 conform；沒有就加 `: CaseIterable`）。

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AccountStoreTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Storage/AccountStore.swift \
        Tests/OrreryTests/AccountStoreTests.swift \
        Sources/OrreryCore/Models/Tool.swift  # 若有改
git commit -m "[ADD] AccountStore: CRUD for accounts pool"
```

---

## Task 3: CredentialAdapter protocol

**Files:**
- Create: `Sources/OrreryCore/Setup/CredentialAdapter.swift`
- Test: `Tests/OrreryTests/CredentialAdapterTests.swift`

- [ ] **Step 1: Write the failing test**

新建 `Tests/OrreryTests/CredentialAdapterTests.swift`：

```swift
import Testing
import Foundation
@testable import OrreryCore

@Suite("CredentialAdapter factory")
struct CredentialAdapterFactoryTests {
    @Test("returns FilesystemCredentialAdapter for codex")
    func codexUsesFilesystem() {
        let adapter = CredentialAdapters.adapter(for: .codex)
        #expect(adapter is FilesystemCredentialAdapter)
    }

    @Test("returns FilesystemCredentialAdapter for gemini")
    func geminiUsesFilesystem() {
        let adapter = CredentialAdapters.adapter(for: .gemini)
        #expect(adapter is FilesystemCredentialAdapter)
    }

    #if os(macOS)
    @Test("returns KeychainCredentialAdapter for claude on macOS")
    func claudeOnMacUsesKeychain() {
        let adapter = CredentialAdapters.adapter(for: .claude)
        #expect(adapter is KeychainCredentialAdapter)
    }
    #else
    @Test("returns FilesystemCredentialAdapter for claude on non-macOS")
    func claudeNonMacUsesFilesystem() {
        let adapter = CredentialAdapters.adapter(for: .claude)
        #expect(adapter is FilesystemCredentialAdapter)
    }
    #endif
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CredentialAdapterFactoryTests`
Expected: FAIL — `cannot find 'CredentialAdapter' in scope`

- [ ] **Step 3: Implement protocol and factory namespace**

新建 `Sources/OrreryCore/Setup/CredentialAdapter.swift`：

```swift
import Foundation

/// 抽象「啟動工具前讓某個 account 的憑證對工具可見」的行為。
/// 不同 (工具, 平台) 組合用不同實作。
public protocol CredentialAdapter: Sendable {
    /// Materialize：把 account 的憑證放到工具預期讀取的位置。
    /// 冪等。如果已經就定位，不重做。
    func materialize(
        account: Account,
        targetConfigDir: URL,
        accountStore: AccountStore
    ) throws

    /// 從 account 池讀回顯示用的帳號資訊（email/plan 等），失敗回 nil。
    func accountInfo(account: Account, accountStore: AccountStore) -> ToolAuth.AccountInfo?
}

/// Factory namespace。Protocol 和 namespace 在 Swift 不能同名，所以 factory 放在 `CredentialAdapters`。
public enum CredentialAdapters {
    public static func adapter(for tool: Tool) -> any CredentialAdapter {
        switch tool {
        case .claude:
            #if os(macOS)
            return KeychainCredentialAdapter()
            #else
            return FilesystemCredentialAdapter(tool: .claude)
            #endif
        case .codex:
            return FilesystemCredentialAdapter(tool: .codex)
        case .gemini:
            return FilesystemCredentialAdapter(tool: .gemini)
        }
    }
}
```

- [ ] **Step 4: Disable factory tests until Task 4/5 supplies the implementations**

Step 1 中寫的 `CredentialAdapterFactoryTests` 此時還無法執行（`FilesystemCredentialAdapter` / `KeychainCredentialAdapter` 尚未存在）。把該 suite 加 `.disabled("enabled after Task 4/5")`：

```swift
@Suite("CredentialAdapter factory", .disabled("enabled after Task 4/5"))
struct CredentialAdapterFactoryTests { ... }
```

確認 build 通過：

Run: `swift build`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Setup/CredentialAdapter.swift \
        Tests/OrreryTests/CredentialAdapterTests.swift
git commit -m "[ADD] CredentialAdapter protocol + factory skeleton"
```

---

## Task 4: FilesystemCredentialAdapter

**Files:**
- Create: `Sources/OrreryCore/Setup/FilesystemCredentialAdapter.swift`
- Modify: `Tests/OrreryTests/CredentialAdapterTests.swift`

- [ ] **Step 1: Write the failing test**

在 `Tests/OrreryTests/CredentialAdapterTests.swift` 加入：

```swift
@Suite("FilesystemCredentialAdapter")
struct FilesystemCredentialAdapterTests {
    var tmpDir: URL!
    var accountStore: AccountStore!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-fs-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        accountStore = AccountStore(homeURL: tmpDir)
    }

    @Test("materialize symlinks codex auth.json into target dir")
    func materializeCodex() throws {
        let account = Account(tool: .codex, displayName: "work")
        try accountStore.save(account)

        // 在 account dir 放入「credentials」檔案
        let accountDir = accountStore.accountDir(id: account.id, tool: .codex)
        let credsURL = accountDir.appendingPathComponent("auth.json")
        try "{\"token\":\"abc\"}".data(using: .utf8)!.write(to: credsURL)

        // 啟動目標目錄
        let targetDir = tmpDir.appendingPathComponent("target-codex")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let adapter = FilesystemCredentialAdapter(tool: .codex)
        try adapter.materialize(account: account, targetConfigDir: targetDir, accountStore: accountStore)

        // 結果：target 內有 auth.json 是 symlink 指向 account dir
        let symlinked = targetDir.appendingPathComponent("auth.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: symlinked.path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: symlinked.path)
        #expect(dest == credsURL.path)
    }

    @Test("materialize is idempotent (no-op when symlink already correct)")
    func idempotent() throws {
        let account = Account(tool: .codex, displayName: "work")
        try accountStore.save(account)
        let credsURL = accountStore.accountDir(id: account.id, tool: .codex)
            .appendingPathComponent("auth.json")
        try "{}".data(using: .utf8)!.write(to: credsURL)

        let targetDir = tmpDir.appendingPathComponent("target-codex-idem")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let adapter = FilesystemCredentialAdapter(tool: .codex)
        try adapter.materialize(account: account, targetConfigDir: targetDir, accountStore: accountStore)
        try adapter.materialize(account: account, targetConfigDir: targetDir, accountStore: accountStore)
        // 不應拋出
    }

    @Test("materialize replaces stale symlink pointing elsewhere")
    func replacesStale() throws {
        let account = Account(tool: .codex, displayName: "new")
        try accountStore.save(account)
        let newCreds = accountStore.accountDir(id: account.id, tool: .codex)
            .appendingPathComponent("auth.json")
        try "{}".data(using: .utf8)!.write(to: newCreds)

        let targetDir = tmpDir.appendingPathComponent("target-codex-stale")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let symlink = targetDir.appendingPathComponent("auth.json")
        let staleTarget = tmpDir.appendingPathComponent("stale.json")
        try "{}".data(using: .utf8)!.write(to: staleTarget)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: staleTarget)

        let adapter = FilesystemCredentialAdapter(tool: .codex)
        try adapter.materialize(account: account, targetConfigDir: targetDir, accountStore: accountStore)

        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path)
        #expect(dest == newCreds.path)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FilesystemCredentialAdapterTests`
Expected: FAIL — `cannot find 'FilesystemCredentialAdapter'`

- [ ] **Step 3: Implement adapter**

新建 `Sources/OrreryCore/Setup/FilesystemCredentialAdapter.swift`：

```swift
import Foundation

public struct FilesystemCredentialAdapter: CredentialAdapter {
    public let tool: Tool
    private let fm = FileManager.default

    public init(tool: Tool) {
        self.tool = tool
    }

    /// 該工具憑證檔在 account dir / target dir 的相對檔名。
    private var credentialFileName: String {
        switch tool {
        case .codex: return "auth.json"
        case .gemini: return "oauth_creds.json"
        case .claude: return ".credentials.json"  // Linux 路徑
        }
    }

    public func materialize(
        account: Account,
        targetConfigDir: URL,
        accountStore: AccountStore
    ) throws {
        let source = accountStore.accountDir(id: account.id, tool: tool)
            .appendingPathComponent(credentialFileName)
        let target = targetConfigDir.appendingPathComponent(credentialFileName)

        // 冪等：若 symlink 已指向正確位置，直接 return
        if let existing = try? fm.destinationOfSymbolicLink(atPath: target.path),
           existing == source.path {
            return
        }

        // 移除任何既有的 target（檔案或舊 symlink）
        if fm.fileExists(atPath: target.path) || (try? fm.attributesOfItem(atPath: target.path)) != nil {
            try fm.removeItem(at: target)
        }

        // 確保目標目錄存在
        try fm.createDirectory(at: targetConfigDir, withIntermediateDirectories: true)

        try fm.createSymbolicLink(at: target, withDestinationURL: source)
    }

    public func accountInfo(account: Account, accountStore: AccountStore) -> ToolAuth.AccountInfo? {
        // 第一版簡化：直接回 displayName，未來再 parse 憑證取 email/plan
        return ToolAuth.AccountInfo(email: nil, plan: nil, displayName: account.displayName)
    }
}
```

> `ToolAuth.AccountInfo` 已存在於 `Sources/OrreryCore/Setup/ToolAuth.swift`。若該型別目前沒有 `displayName` 欄位、初始化器不接收這個參數，先進去那個檔案加上 optional `displayName: String?`（在 init 與 storage 加，default nil 不破壞現有用法），再從本 task commit 帶過。

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FilesystemCredentialAdapterTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Setup/FilesystemCredentialAdapter.swift \
        Sources/OrreryCore/Setup/ToolAuth.swift \
        Tests/OrreryTests/CredentialAdapterTests.swift
git commit -m "[ADD] FilesystemCredentialAdapter: symlink-based materialize"
```

---

## Task 5: KeychainCredentialAdapter (macOS Claude)

**Files:**
- Create: `Sources/OrreryCore/Setup/KeychainCredentialAdapter.swift`
- Modify: `Tests/OrreryTests/CredentialAdapterTests.swift`、`Sources/OrreryCore/Setup/ClaudeKeychain.swift`

- [ ] **Step 1: Add an orrery-account-keyed Keychain helper**

`ClaudeKeychain` 目前用 config-dir 做 service 名稱衍生。我們需要加：

- `serviceName(forOrreryAccount accountID: String)` → `"Claude Code-orrery-<accountID>"`
- `copy(fromService:to:)` 把一個 Keychain item 內容複寫到另一個 service name 下

在 `Sources/OrreryCore/Setup/ClaudeKeychain.swift` 加入：

```swift
extension ClaudeKeychain {
    /// 給 orrery account 用的 Keychain service name。
    public static func serviceName(forOrreryAccount accountID: String) -> String {
        "Claude Code-orrery-\(accountID)"
    }

    #if os(macOS)
    /// 把 srcService 的 password 複寫到 dstService（覆蓋現有）。
    /// 回傳成功與否。
    public static func copyKeychainItem(from srcService: String, to dstService: String) -> Bool {
        // 用 `security find-generic-password -w -s <srcService>` 取出 password
        guard let password = readPassword(service: srcService) else { return false }
        return writePassword(password, service: dstService)
    }

    /// 把資料寫入 orrery account 自己的 service 下（建立新 account 用）。
    public static func storePassword(_ password: String, forOrreryAccount accountID: String) -> Bool {
        writePassword(password, service: serviceName(forOrreryAccount: accountID))
    }

    private static func readPassword(service: String) -> String? {
        let proc = Process()
        proc.launchPath = "/usr/bin/security"
        proc.arguments = ["find-generic-password", "-w", "-s", service]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let raw = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return raw
    }

    private static func writePassword(_ password: String, service: String) -> Bool {
        // -U 更新，沒有則建立
        let proc = Process()
        proc.launchPath = "/usr/bin/security"
        proc.arguments = ["add-generic-password", "-U", "-s", service, "-a", service, "-w", password]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }
    #endif
}
```

> 若 `readPassword` / `writePassword` 在 ClaudeKeychain 內已存在私有版本，沿用既有的並改成這裡的 public/internal 版即可，不要重複實作。

- [ ] **Step 2: Write failing tests for adapter**

在 `Tests/OrreryTests/CredentialAdapterTests.swift` 加入（**macOS-only**）：

```swift
#if os(macOS)
@Suite("KeychainCredentialAdapter (macOS)")
struct KeychainCredentialAdapterTests {
    var tmpDir: URL!
    var accountStore: AccountStore!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-kc-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        accountStore = AccountStore(homeURL: tmpDir)
    }

    @Test("materialize copies token from orrery-account keychain to active key")
    func materializeCopies() throws {
        let accountID = UUID().uuidString
        let orreryService = ClaudeKeychain.serviceName(forOrreryAccount: accountID)
        let claudeActiveService = "Claude Code-credentials-orrery-test-\(UUID().uuidString)"

        // 建一個 orrery account
        let account = Account(
            id: accountID,
            tool: .claude,
            displayName: "test-mac",
            keychainItem: orreryService
        )
        try accountStore.save(account)

        // 在 Keychain 內放一個 dummy token，service = orreryService
        let ok = ClaudeKeychain.storePassword("dummy-token-for-test", forOrreryAccount: accountID)
        #expect(ok)

        let targetDir = tmpDir.appendingPathComponent("target-claude")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        // 我們用 envvar `ORRERY_TEST_CLAUDE_ACTIVE_SERVICE` 注入「active service name」
        // 讓 adapter 在測試環境下不去碰使用者真正的 Claude Keychain entry
        setenv("ORRERY_TEST_CLAUDE_ACTIVE_SERVICE", claudeActiveService, 1)
        defer {
            unsetenv("ORRERY_TEST_CLAUDE_ACTIVE_SERVICE")
            // cleanup keychain
            _ = Process.deleteKeychainItem(service: orreryService)
            _ = Process.deleteKeychainItem(service: claudeActiveService)
        }

        let adapter = KeychainCredentialAdapter()
        try adapter.materialize(account: account, targetConfigDir: targetDir, accountStore: accountStore)

        // 驗證 active service 下能讀到同樣的 token
        let read = ClaudeKeychain.readPasswordForTest(service: claudeActiveService)
        #expect(read == "dummy-token-for-test")
    }
}

// test-only helpers
extension Process {
    static func deleteKeychainItem(service: String) -> Int32 {
        let proc = Process()
        proc.launchPath = "/usr/bin/security"
        proc.arguments = ["delete-generic-password", "-s", service]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }
}

extension ClaudeKeychain {
    static func readPasswordForTest(service: String) -> String? {
        readPassword(service: service)
    }
}
#endif
```

> 這個測試會真的接觸使用者的 Keychain（測試專用 service name 含 UUID 避免衝突），最終 defer 內清掉。CI 上若 macOS runner 沒設定 Keychain unlock，這個 suite 會被跳過。如果 CI 容易壞，可以把整個 suite 加 `.disabled(if: ProcessInfo.processInfo.environment["CI"] != nil)`。

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter KeychainCredentialAdapterTests`
Expected: FAIL — `cannot find 'KeychainCredentialAdapter'`

- [ ] **Step 4: Implement adapter**

新建 `Sources/OrreryCore/Setup/KeychainCredentialAdapter.swift`：

```swift
#if os(macOS)
import Foundation

public struct KeychainCredentialAdapter: CredentialAdapter {
    private let activeServiceOverride: String?

    public init(activeServiceOverride: String? = nil) {
        self.activeServiceOverride = activeServiceOverride
    }

    /// Claude 預期讀取的 Keychain service name。
    /// 一般 = "Claude Code-credentials"。
    /// 測試或 isolated env 可透過環境變數覆寫。
    private var activeKeychainService: String {
        if let override = activeServiceOverride { return override }
        if let test = ProcessInfo.processInfo.environment["ORRERY_TEST_CLAUDE_ACTIVE_SERVICE"] {
            return test
        }
        return "Claude Code-credentials"
    }

    public func materialize(
        account: Account,
        targetConfigDir: URL,
        accountStore: AccountStore
    ) throws {
        guard account.tool == .claude else {
            throw Error.wrongTool(expected: .claude, got: account.tool)
        }
        guard let orreryService = account.keychainItem else {
            throw Error.missingKeychainItem(accountID: account.id)
        }

        try FileManager.default.createDirectory(at: targetConfigDir, withIntermediateDirectories: true)

        let ok = ClaudeKeychain.copyKeychainItem(
            from: orreryService,
            to: activeKeychainService
        )
        guard ok else {
            throw Error.keychainCopyFailed(from: orreryService, to: activeKeychainService)
        }
    }

    public func accountInfo(account: Account, accountStore: AccountStore) -> ToolAuth.AccountInfo? {
        ToolAuth.AccountInfo(email: nil, plan: nil, displayName: account.displayName)
    }

    public enum Error: Swift.Error {
        case wrongTool(expected: Tool, got: Tool)
        case missingKeychainItem(accountID: String)
        case keychainCopyFailed(from: String, to: String)
    }
}
#endif
```

- [ ] **Step 5: 啟用 Task 3 中暫時 disabled 的 factory tests**

把 `CredentialAdapterFactoryTests` 上的 `.disabled(...)` 拿掉，並把測試中 `adapter is FilesystemCredentialAdapter` / `adapter is KeychainCredentialAdapter` 對齊命名（已經對齊的話略過）。

- [ ] **Step 6: Run all CredentialAdapter tests**

Run: `swift test --filter CredentialAdapter`
Expected: PASS（含 macOS Keychain suite）

- [ ] **Step 7: Commit**

```bash
git add Sources/OrreryCore/Setup/KeychainCredentialAdapter.swift \
        Sources/OrreryCore/Setup/ClaudeKeychain.swift \
        Tests/OrreryTests/CredentialAdapterTests.swift
git commit -m "[ADD] KeychainCredentialAdapter: metadata-pointer for macOS Claude"
```

---

## Task 6: OrreryEnvironment.accounts field + EnvironmentStore helpers

**Files:**
- Modify: `Sources/OrreryCore/Models/OrreryEnvironment.swift`
- Modify: `Sources/OrreryCore/Storage/EnvironmentStore.swift`
- Test: `Tests/OrreryTests/EnvironmentStoreTests.swift`

- [ ] **Step 1: Write failing tests**

在 `Tests/OrreryTests/EnvironmentStoreTests.swift` 加入：

```swift
@Suite("EnvironmentStore.accounts")
struct EnvironmentAccountsTests {
    var tmpDir: URL!
    var store: EnvironmentStore!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-env-accts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = EnvironmentStore(homeURL: tmpDir)
    }

    @Test("env.json round-trips accounts field")
    func roundTripAccounts() throws {
        var env = OrreryEnvironment(name: "work")
        env.accounts = [.claude: "acct-123", .codex: "acct-456"]
        try store.save(env)

        let loaded = try store.load(named: "work")
        #expect(loaded.accounts[.claude] == "acct-123")
        #expect(loaded.accounts[.codex] == "acct-456")
        #expect(loaded.accounts[.gemini] == nil)
    }

    @Test("default empty accounts")
    func defaultEmpty() throws {
        let env = OrreryEnvironment(name: "empty")
        try store.save(env)
        let loaded = try store.load(named: "empty")
        #expect(loaded.accounts.isEmpty)
    }

    @Test("envsReferencing returns envs that pin given account")
    func envsReferencing() throws {
        var work = OrreryEnvironment(name: "work")
        work.accounts = [.claude: "shared-acct"]
        try store.save(work)

        var play = OrreryEnvironment(name: "play")
        play.accounts = [.claude: "shared-acct", .codex: "other"]
        try store.save(play)

        var lonely = OrreryEnvironment(name: "lonely")
        lonely.accounts = [.codex: "different"]
        try store.save(lonely)

        let refs = try store.envsReferencing(accountID: "shared-acct", tool: .claude)
        #expect(Set(refs) == ["work", "play"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EnvironmentAccountsTests`
Expected: FAIL — `accounts` 欄位不存在 / `envsReferencing` 找不到

- [ ] **Step 3: Add accounts field to OrreryEnvironment**

修改 `Sources/OrreryCore/Models/OrreryEnvironment.swift`，在 struct body 中加入欄位（位置放在 `memoryStoragePath` 後）：

```swift
    /// 每個工具釘住的 account id。
    /// 沒釘 = key 不存在於字典。
    public var accounts: [Tool: AccountID]
```

並在 init 加入：
```swift
        accounts: [Tool: AccountID] = [:],
```
以及對應的 `self.accounts = accounts`。

> `Tool` 已是 `Hashable` + `Codable`（既有 enum）。Swift 的 `Codable` 對 `[Tool: AccountID]` 預設會編成 array，這在 JSON 上不直觀。請改用 `[String: AccountID]` 在 codable 層，runtime 用 helper 轉。最簡作法：

宣告兩個 properties：

```swift
    /// JSON 上以 `"claude": "<id>"` 形式儲存。
    private var accountsRaw: [String: AccountID]

    public var accounts: [Tool: AccountID] {
        get {
            var out: [Tool: AccountID] = [:]
            for (k, v) in accountsRaw {
                if let tool = Tool(rawValue: k) {
                    out[tool] = v
                }
            }
            return out
        }
        set {
            accountsRaw = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) })
        }
    }
```

在 CodingKeys 中加入 `case accountsRaw = "accounts"`。

> 若 `OrreryEnvironment` 目前沒有顯式 CodingKeys（用 synthesized），需要加上完整 CodingKeys enum、init(from:)/encode(to:) — 或更簡單：直接用 `[String: AccountID]` 作為公開型別，省掉 helper。後者比較簡潔，建議採用：

**簡化方案**：在 model 上直接公開 `[String: AccountID]`，並提供讀寫的 helper extension：

```swift
    /// JSON 上 `"accounts": { "claude": "<id>", ... }`。Key 為 Tool.rawValue。
    public var accounts: [String: AccountID]

    // ... init 帶入 accounts: [String: AccountID] = [:]
```

extension（同檔案）：

```swift
extension OrreryEnvironment {
    public func account(for tool: Tool) -> AccountID? {
        accounts[tool.rawValue]
    }

    public mutating func setAccount(_ id: AccountID?, for tool: Tool) {
        if let id = id {
            accounts[tool.rawValue] = id
        } else {
            accounts.removeValue(forKey: tool.rawValue)
        }
    }
}
```

更新測試 `env.accounts = [.claude: "acct-123"]` → `env.accounts = ["claude": "acct-123"]`（或保留並用 setAccount），用一致風格即可。建議測試也用 String key 形式以對齊 JSON 表示。

- [ ] **Step 4: Add envsReferencing to EnvironmentStore**

在 `Sources/OrreryCore/Storage/EnvironmentStore.swift` 加入：

```swift
extension EnvironmentStore {
    /// 列出所有 env（含 origin）中釘住指定 account 的 env 名稱。
    public func envsReferencing(accountID: AccountID, tool: Tool) throws -> [String] {
        var names: [String] = []
        // 一般 envs
        for name in try listNames() {
            if let env = try? load(named: name),
               env.account(for: tool) == accountID {
                names.append(name)
            }
        }
        // origin（origin 用 OriginConfig，不存於 envs/<UUID>/）
        if let originAcct = loadOriginConfig().accounts[tool.rawValue],
           originAcct == accountID {
            names.append(ReservedEnvironment.defaultName)
        }
        return names
    }
}
```

> 同時 `OriginConfig` 也需要 `accounts: [String: AccountID]` 欄位。在 `OrreryEnvironment.swift` 同檔案中的 `OriginConfig` struct 加上一樣的欄位 + init default `[:]`。

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter EnvironmentAccountsTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/OrreryCore/Models/OrreryEnvironment.swift \
        Sources/OrreryCore/Storage/EnvironmentStore.swift \
        Tests/OrreryTests/EnvironmentStoreTests.swift
git commit -m "[ADD] OrreryEnvironment.accounts field + envsReferencing helper"
```

---

## Task 7: Localization strings for account commands

**Files:**
- Modify: `Sources/OrreryCore/Resources/Localization/en.json`、`zh-Hant.json`、`ja.json`、`keys.md`

- [ ] **Step 1: 加入新的 L10n keys**

在 `en.json` 加入（位置：account 區塊，依現有檔案的字母順序插入）：

```json
"account.abstract": "Manage AI tool accounts (credentials).",
"account.add.abstract": "Add a new account for a tool.",
"account.add.nameHelp": "Display name for this account.",
"account.add.tools.help": "Pick exactly one of --claude, --codex, --gemini (default: --claude).",
"account.add.tools.tooMany": "Pick exactly one of --claude, --codex, --gemini (default: --claude).",
"account.add.namePrompt": "Enter a display name for this account: ",
"account.add.created": "Created account '{name}' for {tool}.",
"account.list.abstract": "List accounts (optionally filtered by tool).",
"account.list.empty": "No accounts yet. Run `orrery account add` to create one.",
"account.list.header.tool": "{tool} accounts:",
"account.list.row": "  - {name} ({id})",
"account.show.abstract": "Show which account is currently pinned per tool in the active env.",
"account.show.row.pinned": "  {tool}: {name}",
"account.show.row.unpinned": "  {tool}: (no account pinned — run `orrery account use` or `orrery account add`)",
"account.show.activeEnv": "Active env: {name}",
"account.use.abstract": "Pin an account to the active env (origin by default).",
"account.use.notFound": "No account '{name}' for {tool}. Run `orrery account list --{tool}` to see options.",
"account.use.pinned": "Pinned {tool} account '{name}' to env '{env}'.",
"account.remove.abstract": "Remove an account from the pool.",
"account.remove.notFound": "No account '{name}' for {tool}.",
"account.remove.stillReferenced": "Account '{name}' is still pinned by env(s): {envs}. Switch them first.",
"account.remove.removed": "Removed account '{name}' for {tool}."
```

> 在 `zh-Hant.json` 和 `ja.json` 加入對等翻譯（**完整**翻譯，不要塞英文佔位）。例如：

`zh-Hant.json` 範例（節錄）：
```json
"account.abstract": "管理 AI 工具帳號（憑證）。",
"account.add.abstract": "新增工具帳號。",
"account.add.nameHelp": "顯示用的帳號名稱。",
"account.add.tools.tooMany": "--claude、--codex、--gemini 三選一（預設 --claude）。",
"account.add.namePrompt": "請輸入帳號顯示名稱：",
"account.add.created": "已建立 {tool} 帳號「{name}」。",
"account.list.abstract": "列出所有帳號（可指定工具）。",
"account.list.empty": "尚未建立任何帳號。執行 `orrery account add` 來建立。",
"account.list.header.tool": "{tool} 帳號：",
"account.list.row": "  - {name}（{id}）",
"account.show.abstract": "顯示目前 env 中各工具釘住的帳號。",
"account.show.row.pinned": "  {tool}：{name}",
"account.show.row.unpinned": "  {tool}：（尚未釘住帳號，請執行 `orrery account use` 或 `orrery account add`）",
"account.show.activeEnv": "目前 env：{name}",
"account.use.abstract": "把帳號釘到目前 env（預設 origin）。",
"account.use.notFound": "{tool} 中找不到帳號「{name}」。執行 `orrery account list --{tool}` 看可用清單。",
"account.use.pinned": "已將 {tool} 帳號「{name}」釘到 env「{env}」。",
"account.remove.abstract": "從帳號池刪除帳號。",
"account.remove.notFound": "{tool} 中找不到帳號「{name}」。",
"account.remove.stillReferenced": "帳號「{name}」仍被以下 env 引用：{envs}。請先切換這些 env 的帳號後再刪除。",
"account.remove.removed": "已刪除 {tool} 帳號「{name}」。"
```

`ja.json` 同樣對等翻譯（略，由實作者填入）。

把所有新 keys 加進 `keys.md` 索引（依該檔現有格式）。

- [ ] **Step 2: 跑 codegen 並 verify build**

Run: `swift build`
Expected: PASS（L10nCodegenTool plugin 會自動跑，產生 `L10n+Generated.swift`）

- [ ] **Step 3: Run existing localization test**

Run: `swift test --filter LocalizationTests`
Expected: PASS（如果有 key 數量檢查，會驗證三個 locale 都對齊）

- [ ] **Step 4: Commit**

```bash
git add Sources/OrreryCore/Resources/Localization/
git commit -m "[ADD] L10n keys for orrery account commands"
```

---

## Task 8: AccountCommand root + AccountAddCommand

**Files:**
- Create: `Sources/OrreryCore/Commands/AccountCommand.swift`
- Create: `Sources/OrreryCore/Commands/AccountAddCommand.swift`
- Modify: `Sources/OrreryCore/Commands/OrreryCommand.swift`（註冊子命令）
- Test: `Tests/OrreryTests/AccountCommandsTests.swift`

- [ ] **Step 1: 失敗測試（AccountAdd 行為）**

新建 `Tests/OrreryTests/AccountCommandsTests.swift`：

```swift
import Testing
import Foundation
@testable import OrreryCore

@Suite("AccountAdd")
struct AccountAddTests {
    var tmpDir: URL!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-cmd-acct-add-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        setenv("ORRERY_HOME", tmpDir.path, 1)
    }

    @Test("rejects when more than one tool flag set")
    func multipleToolFlags() throws {
        // ArgumentParser 在 parse 階段不能直接禁止多 flag，所以我們在 .run() 做檢查
        var cmd = AccountAddCommand()
        cmd.claude = true
        cmd.codex = true
        cmd.name = "x"

        #expect(throws: (any Error).self) {
            try cmd.run()
        }
    }

    @Test("defaults to claude when no tool flag")
    func defaultsToClaude() throws {
        var cmd = AccountAddCommand()
        cmd.name = "default-claude-test"
        cmd.skipLogin = true   // testing-only flag: 不真的觸發登入

        try cmd.run()

        let store = AccountStore.default
        let claudeAccts = try store.list(tool: .claude)
        #expect(claudeAccts.contains(where: { $0.displayName == "default-claude-test" }))
    }

    @Test("creates codex account when --codex set")
    func codexFlag() throws {
        var cmd = AccountAddCommand()
        cmd.codex = true
        cmd.name = "codex-test"
        cmd.skipLogin = true

        try cmd.run()

        let store = AccountStore.default
        #expect(try store.list(tool: .codex).contains(where: { $0.displayName == "codex-test" }))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AccountAddTests`
Expected: FAIL — `cannot find 'AccountAddCommand'`

- [ ] **Step 3: Implement AccountCommand root**

新建 `Sources/OrreryCore/Commands/AccountCommand.swift`：

```swift
import ArgumentParser

public struct AccountCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "account",
        abstract: L10n.Account.abstract,
        subcommands: [
            AccountAddCommand.self,
            AccountListCommand.self,
            AccountShowCommand.self,
            AccountUseCommand.self,
            AccountRemoveCommand.self,
        ]
    )

    public init() {}
}
```

- [ ] **Step 4: Implement AccountAddCommand**

新建 `Sources/OrreryCore/Commands/AccountAddCommand.swift`：

```swift
import ArgumentParser
import Foundation

public struct AccountAddCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: L10n.Account.Add.abstract
    )

    @Flag(name: .long) public var claude: Bool = false
    @Flag(name: .long) public var codex: Bool = false
    @Flag(name: .long) public var gemini: Bool = false

    @Option(name: .long, help: ArgumentHelp(L10n.Account.Add.nameHelp))
    public var name: String?

    /// 測試用：跳過實際工具登入流程，只把 account 寫進 store。
    @Flag(name: .customLong("skip-login"))
    public var skipLogin: Bool = false

    public init() {}

    public func run() throws {
        let tool = try AccountAddCommand.resolveTool(claude: claude, codex: codex, gemini: gemini)
        let displayName = try resolveName()

        let account = Account(tool: tool, displayName: displayName)

        // macOS Claude：account dir 用 Keychain item naming
        var finalAccount = account
        if tool == .claude {
            #if os(macOS)
            finalAccount.keychainItem = ClaudeKeychain.serviceName(forOrreryAccount: account.id)
            #endif
        }

        try AccountStore.default.save(finalAccount)

        if !skipLogin {
            // 觸發工具實際登入流程，把 token 落到 account dir 或 Keychain
            try AccountLoginFlow.run(account: finalAccount)
        }

        print(L10n.Account.Add.created(displayName, tool.rawValue))
    }

    static func resolveTool(claude: Bool, codex: Bool, gemini: Bool) throws -> Tool {
        let count = [claude, codex, gemini].filter { $0 }.count
        if count > 1 {
            throw ValidationError(L10n.Account.Add.Tools.tooMany)
        }
        if codex { return .codex }
        if gemini { return .gemini }
        return .claude   // 預設
    }

    private func resolveName() throws -> String {
        if let n = name, !n.isEmpty { return n }
        // 互動式 prompt
        print(L10n.Account.Add.namePrompt, terminator: "")
        guard let input = readLine()?.trimmingCharacters(in: .whitespaces),
              !input.isEmpty
        else {
            throw ValidationError("Empty name")
        }
        return input
    }
}
```

> `AccountLoginFlow.run(account:)` 還沒實作。第一版可以放最小骨架：

新增到 `Sources/OrreryCore/Setup/AccountLoginFlow.swift`：

```swift
import Foundation

public enum AccountLoginFlow {
    public static func run(account: Account) throws {
        // 第一版 minimal：對每個工具 spawn 該工具的 login 命令，並把產生的憑證搬到 account dir。
        // 對 macOS Claude：spawn `claude login` 之後從 Keychain 把 token 複寫到 orrery service。
        // 對 Codex/Gemini：spawn login 後從 default config dir 把 auth.json/oauth_creds.json copy 進 account dir。
        //
        // 為了避免在這個 task 中爆量，先實作 minimal stub：
        // 直接告訴使用者「請在另一個 terminal 跑該工具的 login 命令」，等他完成後手動指示路徑。
        // 完整實作放到 follow-up task。
        // Stub here is intentional; Task 14 replaces this with the real login flow.
        print("[orrery] account '\(account.displayName)' (\(account.tool.rawValue)) registered.")
        print("[orrery] Login automation arrives in Task 14; for now, run migration or manually populate the account dir.")
    }
}
```

> ⚠️ **這段是有意義的 stub 而不是 placeholder**：建立 account 的 metadata、寫入 store 已完成；login 自動化會在 Task 14 補上。在現階段，使用者可以用 add 把帳號註冊起來、再手動把現有 ~/.claude 等的憑證搬進 account dir（migration 已會自動做）。請在 CHANGELOG 中說明此限制。

- [ ] **Step 5: 註冊到 OrreryCommand**

修改 `Sources/OrreryCore/Commands/OrreryCommand.swift`，把 `AccountCommand.self` 加進 `subcommands` array（位置照字母順序，例如在 `CreateCommand.self` 之前）。

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter AccountAddTests`
Expected: PASS（三個測試）

- [ ] **Step 7: Commit**

```bash
git add Sources/OrreryCore/Commands/AccountCommand.swift \
        Sources/OrreryCore/Commands/AccountAddCommand.swift \
        Sources/OrreryCore/Setup/AccountLoginFlow.swift \
        Sources/OrreryCore/Commands/OrreryCommand.swift \
        Tests/OrreryTests/AccountCommandsTests.swift
git commit -m "[ADD] orrery account add: create accounts in pool"
```

---

## Task 9: AccountListCommand + AccountShowCommand

**Files:**
- Create: `Sources/OrreryCore/Commands/AccountListCommand.swift`
- Create: `Sources/OrreryCore/Commands/AccountShowCommand.swift`
- Modify: `Tests/OrreryTests/AccountCommandsTests.swift`

- [ ] **Step 1: Failing tests for list/show**

加入到 `AccountCommandsTests.swift`：

```swift
@Suite("AccountList")
struct AccountListTests {
    var tmpDir: URL!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-cmd-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        setenv("ORRERY_HOME", tmpDir.path, 1)
    }

    @Test("list returns 'empty' message when no accounts")
    func empty() throws {
        var cmd = AccountListCommand()
        let output = try captureOutput { try cmd.run() }
        #expect(output.contains("No accounts yet"))
    }

    @Test("list shows accounts grouped by tool")
    func grouped() throws {
        let store = AccountStore.default
        try store.save(Account(tool: .claude, displayName: "work"))
        try store.save(Account(tool: .codex, displayName: "personal"))

        var cmd = AccountListCommand()
        let output = try captureOutput { try cmd.run() }
        #expect(output.contains("claude accounts"))
        #expect(output.contains("codex accounts"))
        #expect(output.contains("work"))
        #expect(output.contains("personal"))
    }

    @Test("list with --codex shows only codex pool")
    func filterByTool() throws {
        let store = AccountStore.default
        try store.save(Account(tool: .claude, displayName: "should-not-show"))
        try store.save(Account(tool: .codex, displayName: "yes-show"))

        var cmd = AccountListCommand()
        cmd.codex = true
        let output = try captureOutput { try cmd.run() }
        #expect(output.contains("yes-show"))
        #expect(!output.contains("should-not-show"))
    }
}

@Suite("AccountShow")
struct AccountShowTests {
    var tmpDir: URL!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-cmd-show-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        setenv("ORRERY_HOME", tmpDir.path, 1)
    }

    @Test("show with no env pinned uses origin and shows unpinned rows")
    func unpinnedRows() throws {
        var cmd = AccountShowCommand()
        let output = try captureOutput { try cmd.run() }
        #expect(output.contains("origin"))
        #expect(output.contains("no account pinned"))
    }

    @Test("show displays pinned account display name")
    func pinned() throws {
        let acctStore = AccountStore.default
        let acct = Account(tool: .claude, displayName: "work-display")
        try acctStore.save(acct)

        // 直接設定 origin 的 pin
        let envStore = EnvironmentStore.default
        var origin = envStore.loadOriginConfig()
        origin.accounts["claude"] = acct.id
        try envStore.saveOriginConfig(origin)

        var cmd = AccountShowCommand()
        let output = try captureOutput { try cmd.run() }
        #expect(output.contains("work-display"))
    }
}

// test helper
func captureOutput(_ block: () throws -> Void) rethrows -> String {
    let pipe = Pipe()
    let saved = dup(fileno(stdout))
    dup2(pipe.fileHandleForWriting.fileDescriptor, fileno(stdout))
    defer {
        fflush(stdout)
        dup2(saved, fileno(stdout))
        close(saved)
    }
    try block()
    fflush(stdout)
    try pipe.fileHandleForWriting.close()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}
```

> `captureOutput` 在 Linux 上行為一致。CI 若不支援，可放寬為直接斷言 `cmd.run()` 不拋出，跳過 output 字串檢查。

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "AccountList|AccountShow"`
Expected: FAIL

- [ ] **Step 3: Implement AccountListCommand**

新建 `Sources/OrreryCore/Commands/AccountListCommand.swift`：

```swift
import ArgumentParser
import Foundation

public struct AccountListCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: L10n.Account.List.abstract
    )

    @Flag(name: .long) public var claude: Bool = false
    @Flag(name: .long) public var codex: Bool = false
    @Flag(name: .long) public var gemini: Bool = false

    public init() {}

    public func run() throws {
        let store = AccountStore.default
        let filter: Tool? = {
            // 多選同時下 → 也視為 "show all"，避免使用者意外得到空結果
            let count = [claude, codex, gemini].filter { $0 }.count
            if count != 1 { return nil }
            if claude { return .claude }
            if codex { return .codex }
            if gemini { return .gemini }
            return nil
        }()

        let grouped: [Tool: [Account]]
        if let f = filter {
            let xs = try store.list(tool: f)
            grouped = xs.isEmpty ? [:] : [f: xs]
        } else {
            grouped = try store.listAll()
        }

        if grouped.isEmpty {
            print(L10n.Account.List.empty)
            return
        }

        for tool in Tool.allCases {
            guard let accts = grouped[tool], !accts.isEmpty else { continue }
            print(L10n.Account.List.Header.tool(tool.rawValue))
            for acct in accts {
                print(L10n.Account.List.row(acct.displayName, acct.id))
            }
        }
    }
}
```

- [ ] **Step 4: Implement AccountShowCommand**

新建 `Sources/OrreryCore/Commands/AccountShowCommand.swift`：

```swift
import ArgumentParser
import Foundation

public struct AccountShowCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: L10n.Account.Show.abstract
    )

    public init() {}

    public func run() throws {
        let envStore = EnvironmentStore.default
        let acctStore = AccountStore.default

        let activeEnvName: String
        let pins: [String: AccountID]
        if let current = try envStore.current(),
           current != ReservedEnvironment.defaultName {
            activeEnvName = current
            pins = (try? envStore.load(named: current).accounts) ?? [:]
        } else {
            activeEnvName = ReservedEnvironment.defaultName
            pins = envStore.loadOriginConfig().accounts
        }

        print(L10n.Account.Show.activeEnv(activeEnvName))
        for tool in Tool.allCases {
            if let id = pins[tool.rawValue],
               let acct = try? acctStore.load(id: id, tool: tool) {
                print(L10n.Account.Show.Row.pinned(tool.rawValue, acct.displayName))
            } else {
                print(L10n.Account.Show.Row.unpinned(tool.rawValue))
            }
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter "AccountList|AccountShow"`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/OrreryCore/Commands/AccountListCommand.swift \
        Sources/OrreryCore/Commands/AccountShowCommand.swift \
        Tests/OrreryTests/AccountCommandsTests.swift
git commit -m "[ADD] orrery account list & show"
```

---

## Task 10: AccountUseCommand

**Files:**
- Create: `Sources/OrreryCore/Commands/AccountUseCommand.swift`
- Modify: `Tests/OrreryTests/AccountCommandsTests.swift`

- [ ] **Step 1: Failing tests**

加入：

```swift
@Suite("AccountUse")
struct AccountUseTests {
    var tmpDir: URL!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-cmd-use-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        setenv("ORRERY_HOME", tmpDir.path, 1)
    }

    @Test("use pins claude account to origin when no env active")
    func pinsToOrigin() throws {
        let acctStore = AccountStore.default
        let acct = Account(tool: .claude, displayName: "work")
        try acctStore.save(acct)

        var cmd = AccountUseCommand()
        cmd.name = "work"
        try cmd.run()

        let origin = EnvironmentStore.default.loadOriginConfig()
        #expect(origin.accounts["claude"] == acct.id)
    }

    @Test("use pins account to current env when one is active")
    func pinsToCurrentEnv() throws {
        let envStore = EnvironmentStore.default
        let env = OrreryEnvironment(name: "work-env")
        try envStore.save(env)
        try envStore.setCurrent("work-env")

        let acct = Account(tool: .claude, displayName: "personal")
        try AccountStore.default.save(acct)

        var cmd = AccountUseCommand()
        cmd.name = "personal"
        try cmd.run()

        let loaded = try envStore.load(named: "work-env")
        #expect(loaded.accounts["claude"] == acct.id)

        // origin 不該被改
        #expect(envStore.loadOriginConfig().accounts["claude"] == nil)
    }

    @Test("use throws when account name not found")
    func notFound() throws {
        var cmd = AccountUseCommand()
        cmd.name = "ghost"
        #expect(throws: (any Error).self) { try cmd.run() }
    }
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `swift test --filter AccountUseTests`
Expected: FAIL

- [ ] **Step 3: Implement**

新建 `Sources/OrreryCore/Commands/AccountUseCommand.swift`：

```swift
import ArgumentParser
import Foundation

public struct AccountUseCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "use",
        abstract: L10n.Account.Use.abstract
    )

    @Flag(name: .long) public var claude: Bool = false
    @Flag(name: .long) public var codex: Bool = false
    @Flag(name: .long) public var gemini: Bool = false

    @Option(name: .long)
    public var name: String

    public init() {}

    public func run() throws {
        let tool = try AccountAddCommand.resolveTool(claude: claude, codex: codex, gemini: gemini)
        let acctStore = AccountStore.default
        guard let acct = try acctStore.findByDisplayName(name, tool: tool) else {
            throw ValidationError(L10n.Account.Use.notFound(name, tool.rawValue))
        }

        let envStore = EnvironmentStore.default
        let targetEnvName: String
        if let current = try envStore.current(),
           current != ReservedEnvironment.defaultName {
            var env = try envStore.load(named: current)
            env.accounts[tool.rawValue] = acct.id
            try envStore.save(env)
            targetEnvName = current
        } else {
            var origin = envStore.loadOriginConfig()
            origin.accounts[tool.rawValue] = acct.id
            try envStore.saveOriginConfig(origin)
            targetEnvName = ReservedEnvironment.defaultName
        }

        print(L10n.Account.Use.pinned(tool.rawValue, name, targetEnvName))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AccountUseTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Commands/AccountUseCommand.swift \
        Tests/OrreryTests/AccountCommandsTests.swift
git commit -m "[ADD] orrery account use: pin account to active env / origin"
```

---

## Task 11: AccountRemoveCommand（含引用檢查）

**Files:**
- Create: `Sources/OrreryCore/Commands/AccountRemoveCommand.swift`
- Modify: `Tests/OrreryTests/AccountCommandsTests.swift`

- [ ] **Step 1: Failing tests**

```swift
@Suite("AccountRemove")
struct AccountRemoveTests {
    var tmpDir: URL!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-cmd-remove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        setenv("ORRERY_HOME", tmpDir.path, 1)
    }

    @Test("removes unreferenced account")
    func removeOK() throws {
        let acct = Account(tool: .claude, displayName: "to-delete")
        try AccountStore.default.save(acct)

        var cmd = AccountRemoveCommand()
        cmd.name = "to-delete"
        try cmd.run()

        #expect(try AccountStore.default.list(tool: .claude).isEmpty)
    }

    @Test("blocks removal when env references the account")
    func blocksWhenReferenced() throws {
        let acct = Account(tool: .claude, displayName: "in-use")
        try AccountStore.default.save(acct)

        let envStore = EnvironmentStore.default
        var env = OrreryEnvironment(name: "ref-env")
        env.accounts["claude"] = acct.id
        try envStore.save(env)

        var cmd = AccountRemoveCommand()
        cmd.name = "in-use"
        #expect(throws: (any Error).self) { try cmd.run() }

        // account 仍在
        #expect(try AccountStore.default.findByDisplayName("in-use", tool: .claude) != nil)
    }
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `swift test --filter AccountRemoveTests`
Expected: FAIL

- [ ] **Step 3: Implement**

新建 `Sources/OrreryCore/Commands/AccountRemoveCommand.swift`：

```swift
import ArgumentParser
import Foundation

public struct AccountRemoveCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: L10n.Account.Remove.abstract
    )

    @Flag(name: .long) public var claude: Bool = false
    @Flag(name: .long) public var codex: Bool = false
    @Flag(name: .long) public var gemini: Bool = false

    @Option(name: .long)
    public var name: String

    public init() {}

    public func run() throws {
        let tool = try AccountAddCommand.resolveTool(claude: claude, codex: codex, gemini: gemini)
        let acctStore = AccountStore.default
        guard let acct = try acctStore.findByDisplayName(name, tool: tool) else {
            throw ValidationError(L10n.Account.Remove.notFound(name, tool.rawValue))
        }

        let envStore = EnvironmentStore.default
        let refs = try envStore.envsReferencing(accountID: acct.id, tool: tool)
        if !refs.isEmpty {
            throw ValidationError(
                L10n.Account.Remove.stillReferenced(name, refs.joined(separator: ", "))
            )
        }

        try acctStore.delete(id: acct.id, tool: tool)

        // macOS Claude：同時清掉 orrery 自己建立的 Keychain item
        #if os(macOS)
        if tool == .claude, let kc = acct.keychainItem {
            _ = Process.deleteKeychainItem(service: kc)  // best effort
        }
        #endif

        print(L10n.Account.Remove.removed(name, tool.rawValue))
    }
}

#if os(macOS)
extension Process {
    fileprivate static func deleteKeychainItem(service: String) -> Int32 {
        let proc = Process()
        proc.launchPath = "/usr/bin/security"
        proc.arguments = ["delete-generic-password", "-s", service]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }
}
#endif
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AccountRemoveTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Commands/AccountRemoveCommand.swift \
        Tests/OrreryTests/AccountCommandsTests.swift
git commit -m "[ADD] orrery account remove: block when referenced by env"
```

---

## Task 12: RunCommand materialize integration

**Files:**
- Modify: `Sources/OrreryCore/Commands/RunCommand.swift`
- Test: `Tests/OrreryTests/RunCommandTests.swift`（已存在 → 加 case；若沒有就 create）

- [ ] **Step 1: Failing test**

在 `RunCommandTests.swift`（或新建）加入：

```swift
@Suite("RunCommand materialize")
struct RunCommandMaterializeTests {
    var tmpDir: URL!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-run-mat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        setenv("ORRERY_HOME", tmpDir.path, 1)
    }

    @Test("materialize symlinks codex auth.json before exec preparation")
    func materializeCodexBeforeExec() throws {
        // setup: account + pin
        let acct = Account(tool: .codex, displayName: "x")
        try AccountStore.default.save(acct)
        try ("{\"t\":\"y\"}").data(using: .utf8)!
            .write(to: AccountStore.default.accountDir(id: acct.id, tool: .codex)
                .appendingPathComponent("auth.json"))

        var origin = EnvironmentStore.default.loadOriginConfig()
        origin.accounts["codex"] = acct.id
        try EnvironmentStore.default.saveOriginConfig(origin)

        // 呼叫 prepare 方法（exec 之前的 hook）
        try RunCommand.prepareMaterialize(tool: .codex, envName: ReservedEnvironment.defaultName)

        // 驗證 origin 的 codex config dir 內 auth.json 是 symlink
        let target = EnvironmentStore.default.originConfigDir(tool: .codex)
            .appendingPathComponent("auth.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RunCommandMaterializeTests`
Expected: FAIL — `prepareMaterialize` 不存在

- [ ] **Step 3: Add prepareMaterialize hook to RunCommand**

在 `Sources/OrreryCore/Commands/RunCommand.swift` 找到「啟動工具子進程」的位置（搜尋 `exec` / `Process()` / spawn 相關），在 `Process.run()` 之前插入：

```swift
extension RunCommand {
    /// 啟動工具子進程前必呼叫：依當前 env / origin 的 pin 把憑證 materialize 到 tool config dir。
    public static func prepareMaterialize(tool: Tool, envName: String) throws {
        let envStore = EnvironmentStore.default
        let acctStore = AccountStore.default

        let pinnedID: AccountID?
        let targetDir: URL
        if envName == ReservedEnvironment.defaultName {
            pinnedID = envStore.loadOriginConfig().accounts[tool.rawValue]
            targetDir = envStore.originConfigDir(tool: tool)
        } else {
            let env = try envStore.load(named: envName)
            pinnedID = env.accounts[tool.rawValue]
            targetDir = envStore.toolConfigDir(tool: tool, environment: envName)
        }

        guard let id = pinnedID else {
            // 未釘 account — 友善提示後繼續（讓工具自己處理「沒登入」的狀態）
            print("[orrery] no \(tool.rawValue) account pinned in env '\(envName)'. " +
                  "Run `orrery account add` then `orrery account use`.")
            return
        }

        let account = try acctStore.load(id: id, tool: tool)
        let adapter = CredentialAdapters.adapter(for: tool)
        try adapter.materialize(account: account, targetConfigDir: targetDir, accountStore: acctStore)
    }
}
```

在 RunCommand 主 `run()` 內、exec 前找一行最合適的位置呼叫（例如 spawn 之前）：

```swift
try Self.prepareMaterialize(tool: chosenTool, envName: activeEnvName)
```

> 既有 RunCommand 的「啟動 spawn」流程細節依各 Tool 而異，請在實際檔案中**為每個 spawn 分支**都呼叫 `prepareMaterialize`。

- [ ] **Step 4: Run all tests to verify nothing regressed**

Run: `swift test --filter RunCommand`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Commands/RunCommand.swift \
        Tests/OrreryTests/RunCommandTests.swift
git commit -m "[ADD] RunCommand: materialize credentials before spawn"
```

---

## Task 13: AccountMigration

**Files:**
- Create: `Sources/OrreryCore/Setup/AccountMigration.swift`
- Test: `Tests/OrreryTests/AccountMigrationTests.swift`
- Modify: `Sources/OrreryCore/Commands/OrreryCommand.swift`（在 main entry 觸發遷移）

- [ ] **Step 1: Failing test**

新建 `Tests/OrreryTests/AccountMigrationTests.swift`：

```swift
import Testing
import Foundation
@testable import OrreryCore

@Suite("AccountMigration")
struct AccountMigrationTests {
    var tmpDir: URL!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-mig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    @Test("skips when no envs exist")
    func skipWhenEmpty() throws {
        try AccountMigration.runIfNeeded(homeURL: tmpDir)
        // 不該 throw、也不該建 accounts dir
        let accountsDir = tmpDir.appendingPathComponent("accounts")
        #expect(!FileManager.default.fileExists(atPath: accountsDir.path))
    }

    @Test("creates flag file after first run")
    func createsFlag() throws {
        // 建一個假 origin 結構但沒實際憑證
        let origin = tmpDir.appendingPathComponent("origin")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try "{}".data(using: .utf8)!.write(to: origin.appendingPathComponent("config.json"))

        try AccountMigration.runIfNeeded(homeURL: tmpDir)

        let flag = tmpDir.appendingPathComponent(".migration-v3")
        #expect(FileManager.default.fileExists(atPath: flag.path))
    }

    @Test("does not re-run when flag exists")
    func skipsWhenFlagExists() throws {
        let flag = tmpDir.appendingPathComponent(".migration-v3")
        try "1".data(using: .utf8)!.write(to: flag)

        // 即使有 origin 結構也不應產生 backup
        try AccountMigration.runIfNeeded(homeURL: tmpDir)

        let backupDirs = (try? FileManager.default.contentsOfDirectory(
            at: tmpDir.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )) ?? []
        let backups = backupDirs.filter { $0.lastPathComponent.hasPrefix(".orrery-backup-") }
        // 沒有針對這個 tmpDir 的 backup
        #expect(!backups.contains(where: { $0.lastPathComponent.contains(tmpDir.lastPathComponent) }))
    }

    @Test("extracts codex auth.json from env into accounts pool")
    func extractsCodex() throws {
        // 建一個 env 結構，內含 codex auth.json
        let envID = UUID().uuidString
        let envDir = tmpDir.appendingPathComponent("envs/\(envID)")
        try FileManager.default.createDirectory(at: envDir, withIntermediateDirectories: true)

        let codexDir = envDir.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let authData = "{\"token\":\"abc\"}".data(using: .utf8)!
        try authData.write(to: codexDir.appendingPathComponent("auth.json"))

        // env.json
        let envJSON = """
        {
          "id": "\(envID)",
          "name": "work",
          "description": "",
          "createdAt": "2026-01-01T00:00:00Z",
          "lastUsed": "2026-01-01T00:00:00Z",
          "tools": ["codex"],
          "env": {},
          "isolatedSessionTools": [],
          "isolateMemory": true,
          "accounts": {}
        }
        """
        try envJSON.data(using: .utf8)!.write(to: envDir.appendingPathComponent("env.json"))

        try AccountMigration.runIfNeeded(homeURL: tmpDir)

        // accounts pool 中應有一個 codex account
        let acctStore = AccountStore(homeURL: tmpDir)
        let codexAccts = try acctStore.list(tool: .codex)
        #expect(codexAccts.count == 1)

        // env.json 應引用該 account
        let envStore = EnvironmentStore(homeURL: tmpDir)
        let env = try envStore.load(named: "work")
        #expect(env.accounts["codex"] == codexAccts.first?.id)
    }
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `swift test --filter AccountMigrationTests`
Expected: FAIL — `AccountMigration` 不存在

- [ ] **Step 3: Implement**

新建 `Sources/OrreryCore/Setup/AccountMigration.swift`：

```swift
import Foundation
import Crypto

public enum AccountMigration {
    public static let flagFileName = ".migration-v3"

    public static func runIfNeeded(homeURL: URL) throws {
        let flagURL = homeURL.appendingPathComponent(flagFileName)
        if FileManager.default.fileExists(atPath: flagURL.path) { return }

        // 沒有任何 env 或 origin → 視為新安裝、直接寫旗標
        if !FileManager.default.fileExists(atPath: homeURL.path) {
            return  // home 還沒建，新安裝走標準流程
        }

        let envsURL = homeURL.appendingPathComponent("envs")
        let originURL = homeURL.appendingPathComponent("origin")
        let hasAnything = FileManager.default.fileExists(atPath: envsURL.path)
            || FileManager.default.fileExists(atPath: originURL.path)
        if !hasAnything {
            try writeFlag(at: flagURL)
            return
        }

        // 1. 備份
        try backup(homeURL: homeURL)

        // 2. 對 origin、所有 env，extract 憑證進 accounts pool
        let envStore = EnvironmentStore(homeURL: homeURL)
        let acctStore = AccountStore(homeURL: homeURL)

        for tool in Tool.allCases {
            // Origin
            if envStore.isOriginManaged(tool: tool) {
                try migrateOrigin(tool: tool, envStore: envStore, acctStore: acctStore)
            }
            // 一般 envs
            for envName in (try? envStore.listNames()) ?? [] {
                try migrateEnv(envName: envName, tool: tool, envStore: envStore, acctStore: acctStore)
            }
        }

        try writeFlag(at: flagURL)
    }

    private static func writeFlag(at url: URL) throws {
        try "v3".data(using: .utf8)!.write(to: url)
    }

    private static func backup(homeURL: URL) throws {
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = homeURL.deletingLastPathComponent()
            .appendingPathComponent(".orrery-backup-\(ts)")
        try FileManager.default.copyItem(at: homeURL, to: backup)
        print("[orrery migration] backup at \(backup.path)")
    }

    private static func migrateOrigin(
        tool: Tool,
        envStore: EnvironmentStore,
        acctStore: AccountStore
    ) throws {
        let configDir = envStore.originConfigDir(tool: tool)
        guard let fingerprint = try credentialFingerprint(tool: tool, in: configDir) else { return }

        let accountID = try ensureAccount(
            tool: tool,
            displayName: ReservedEnvironment.defaultName,
            fingerprint: fingerprint,
            sourceDir: configDir,
            acctStore: acctStore
        )

        var origin = envStore.loadOriginConfig()
        origin.accounts[tool.rawValue] = accountID
        try envStore.saveOriginConfig(origin)
    }

    private static func migrateEnv(
        envName: String,
        tool: Tool,
        envStore: EnvironmentStore,
        acctStore: AccountStore
    ) throws {
        let configDir = envStore.toolConfigDir(tool: tool, environment: envName)
        guard let fingerprint = try credentialFingerprint(tool: tool, in: configDir) else { return }

        let accountID = try ensureAccount(
            tool: tool,
            displayName: envName,
            fingerprint: fingerprint,
            sourceDir: configDir,
            acctStore: acctStore
        )

        var env = try envStore.load(named: envName)
        env.accounts[tool.rawValue] = accountID
        try envStore.save(env)
    }

    /// 計算工具憑證的「指紋」。檔案型 → 內容 SHA256；Keychain 型 → password SHA256。
    /// 沒登入過回 nil。
    private static func credentialFingerprint(tool: Tool, in configDir: URL) throws -> String? {
        let fileName: String
        switch tool {
        case .codex: fileName = "auth.json"
        case .gemini: fileName = "oauth_creds.json"
        case .claude:
            #if os(macOS)
            // Keychain：直接讀 service 對應的 password
            let service = ClaudeKeychain.service(for: configDir.path)
            // 用 helper 讀 password 後 hash（reuse Task 5 中的 readPassword）
            // 為避免 import 細節，假設新增 internal helper：
            return ClaudeKeychain.credentialFingerprint(forService: service)
            #else
            fileName = ".credentials.json"
            #endif
        }
        let url = configDir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func ensureAccount(
        tool: Tool,
        displayName: String,
        fingerprint: String,
        sourceDir: URL,
        acctStore: AccountStore
    ) throws -> AccountID {
        // 去重：列現有 accounts，比對指紋
        for acct in try acctStore.list(tool: tool) {
            let acctDir = acctStore.accountDir(id: acct.id, tool: tool)
            if let existing = try? credentialFingerprintInAccount(tool: tool, accountDir: acctDir, account: acct),
               existing == fingerprint {
                return acct.id
            }
        }

        // 新建
        var account = Account(tool: tool, displayName: uniqueDisplayName(displayName, tool: tool, acctStore: acctStore))
        #if os(macOS)
        if tool == .claude {
            account.keychainItem = ClaudeKeychain.serviceName(forOrreryAccount: account.id)
        }
        #endif
        try acctStore.save(account)

        // 把憑證搬到 account dir
        let dst = acctStore.accountDir(id: account.id, tool: tool)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        switch tool {
        case .codex:
            try FileManager.default.copyItem(
                at: sourceDir.appendingPathComponent("auth.json"),
                to: dst.appendingPathComponent("auth.json")
            )
        case .gemini:
            try FileManager.default.copyItem(
                at: sourceDir.appendingPathComponent("oauth_creds.json"),
                to: dst.appendingPathComponent("oauth_creds.json")
            )
        case .claude:
            #if os(macOS)
            // 把 source Keychain item 複製到 orrery account 專屬 service
            let srcService = ClaudeKeychain.service(for: sourceDir.path)
            _ = ClaudeKeychain.copyKeychainItem(from: srcService, to: account.keychainItem!)
            #else
            try FileManager.default.copyItem(
                at: sourceDir.appendingPathComponent(".credentials.json"),
                to: dst.appendingPathComponent(".credentials.json")
            )
            #endif
        }

        return account.id
    }

    private static func credentialFingerprintInAccount(tool: Tool, accountDir: URL, account: Account) throws -> String? {
        switch tool {
        case .codex:
            let data = try Data(contentsOf: accountDir.appendingPathComponent("auth.json"))
            return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        case .gemini:
            let data = try Data(contentsOf: accountDir.appendingPathComponent("oauth_creds.json"))
            return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        case .claude:
            #if os(macOS)
            return ClaudeKeychain.credentialFingerprint(forService: account.keychainItem ?? "")
            #else
            let data = try Data(contentsOf: accountDir.appendingPathComponent(".credentials.json"))
            return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
            #endif
        }
    }

    private static func uniqueDisplayName(_ base: String, tool: Tool, acctStore: AccountStore) -> String {
        var name = base
        var n = 2
        while (try? acctStore.findByDisplayName(name, tool: tool)) ?? nil != nil {
            name = "\(base)-\(n)"
            n += 1
        }
        return name
    }
}
```

> 需要新增 `ClaudeKeychain.credentialFingerprint(forService:)` helper（macOS only）：在該檔案 extension 內加：
> ```swift
> #if os(macOS)
> extension ClaudeKeychain {
>     public static func credentialFingerprint(forService service: String) -> String? {
>         guard let pw = readPassword(service: service) else { return nil }
>         let data = Data(pw.utf8)
>         return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
>     }
> }
> #endif
> ```
> 並在檔頂加上 `import Crypto`（swift-crypto 已是 Package.swift 中的依賴，若無需 add）。

> 若 Package.swift 無 swift-crypto，先在 Task 13 一開始加入依賴：在 `Package.swift` 的 dependencies 加 `.package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")`，並在 OrreryCore target 加 `.product(name: "Crypto", package: "swift-crypto")`。

- [ ] **Step 4: 在 OrreryCommand 觸發遷移**

修改 `Sources/OrreryCore/Commands/OrreryCommand.swift`，在 `run()`（或 main entry）最早期加入：

```swift
try AccountMigration.runIfNeeded(homeURL: EnvironmentStore.default.homeURL)
```

> 若 OrreryCommand 是 async / parsable struct with subcommands，遷移應放在 subcommand dispatch 之前的位置。常見作法是覆寫 `static func main()` 或在每個 subcommand validate 中呼叫——選最影響面最小的位置即可。

- [ ] **Step 5: Phantom supervisor 暫停**

在 `AccountMigration.runIfNeeded` 中於 backup 之前加入：

```swift
if let pid = PhantomSupervisor.runningPID(homeURL: homeURL) {
    print("[orrery migration] phantom supervisor running (pid \(pid)). Please exit all phantom sessions, then re-run.")
    throw MigrationError.phantomActive(pid: pid)
}
```

並新增 `enum MigrationError: Error { case phantomActive(pid: Int32) }`。

> `PhantomSupervisor.runningPID(homeURL:)` 需要在 `Sources/OrreryCore/Setup/PhantomSupervisor.swift`（或對應檔案）中加入。第一版可以掃描 `~/.orrery/.supervisor.pid` 之類的 lockfile，如果不存在就回 nil；若 supervisor 還沒建這個檔，這個 hook 就先空轉。實作為：

```swift
public enum PhantomSupervisor {
    public static func runningPID(homeURL: URL) -> Int32? {
        let lockURL = homeURL.appendingPathComponent(".supervisor.pid")
        guard let data = try? Data(contentsOf: lockURL),
              let pidStr = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidStr)
        else { return nil }
        // 確認 process 還活著
        if kill(pid, 0) == 0 { return pid }
        return nil
    }
}
```

對應寫 lockfile 的位置（既有 supervisor 的 activate.sh）下個 task 再協調。

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter AccountMigrationTests`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add Sources/OrreryCore/Setup/AccountMigration.swift \
        Sources/OrreryCore/Setup/PhantomSupervisor.swift \
        Sources/OrreryCore/Setup/ClaudeKeychain.swift \
        Sources/OrreryCore/Commands/OrreryCommand.swift \
        Package.swift Package.resolved \
        Tests/OrreryTests/AccountMigrationTests.swift
git commit -m "[ADD] AccountMigration: v2→v3 auto-migrate credentials to pool"
```

---

## Task 14: Wire AccountLoginFlow to actual tool login

**Files:**
- Modify: `Sources/OrreryCore/Setup/AccountLoginFlow.swift`
- Test: `Tests/OrreryTests/AccountLoginFlowTests.swift`

- [ ] **Step 1: Failing test for filesystem-based login**

```swift
import Testing
import Foundation
@testable import OrreryCore

@Suite("AccountLoginFlow")
struct AccountLoginFlowTests {
    var tmpDir: URL!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        setenv("ORRERY_HOME", tmpDir.path, 1)
    }

    @Test("filesystem flow copies auth.json from temp config dir to account dir")
    func filesystemCopies() throws {
        let account = Account(tool: .codex, displayName: "test")
        try AccountStore.default.save(account)

        // 模擬：login 命令把 auth.json 寫到 staging dir
        let staging = tmpDir.appendingPathComponent("staging-codex")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try ("{\"login\":\"yes\"}").data(using: .utf8)!
            .write(to: staging.appendingPathComponent("auth.json"))

        try AccountLoginFlow.importFrom(stagingDir: staging, into: account)

        // account dir 內應有 auth.json
        let acctDir = AccountStore.default.accountDir(id: account.id, tool: .codex)
        #expect(FileManager.default.fileExists(atPath: acctDir.appendingPathComponent("auth.json").path))
    }
}
```

- [ ] **Step 2: Implement importFrom**

更新 `Sources/OrreryCore/Setup/AccountLoginFlow.swift`：

```swift
import Foundation

public enum AccountLoginFlow {
    public static func run(account: Account) throws {
        switch account.tool {
        case .claude:
            try runClaudeLogin(account: account)
        case .codex:
            try runFilesystemLogin(account: account, configDirEnvVar: "CODEX_HOME", credentialFile: "auth.json", loginArgs: ["login"])
        case .gemini:
            try runFilesystemLogin(account: account, configDirEnvVar: "GEMINI_CONFIG_DIR", credentialFile: "oauth_creds.json", loginArgs: ["auth", "login"])
        }
    }

    /// 給測試或外部流程使用：把已產生在 stagingDir 的憑證 import 進 account。
    public static func importFrom(stagingDir: URL, into account: Account) throws {
        let acctStore = AccountStore.default
        let dst = acctStore.accountDir(id: account.id, tool: account.tool)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        switch account.tool {
        case .codex:
            try copyOverwriting(
                from: stagingDir.appendingPathComponent("auth.json"),
                to: dst.appendingPathComponent("auth.json")
            )
        case .gemini:
            try copyOverwriting(
                from: stagingDir.appendingPathComponent("oauth_creds.json"),
                to: dst.appendingPathComponent("oauth_creds.json")
            )
        case .claude:
            #if os(macOS)
            guard let dstService = account.keychainItem else {
                throw LoginError.missingKeychainItem
            }
            let stagingService = ClaudeKeychain.service(for: stagingDir.path)
            _ = ClaudeKeychain.copyKeychainItem(from: stagingService, to: dstService)
            #else
            try copyOverwriting(
                from: stagingDir.appendingPathComponent(".credentials.json"),
                to: dst.appendingPathComponent(".credentials.json")
            )
            #endif
        }
    }

    private static func copyOverwriting(from src: URL, to dst: URL) throws {
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.copyItem(at: src, to: dst)
    }

    private static func runFilesystemLogin(
        account: Account,
        configDirEnvVar: String,
        credentialFile: String,
        loginArgs: [String]
    ) throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        // spawn 工具 CLI with custom CONFIG_DIR=staging
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [account.tool.rawValue] + loginArgs
        var env = ProcessInfo.processInfo.environment
        env[configDirEnvVar] = staging.path
        proc.environment = env

        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw LoginError.toolExitedNonZero(status: proc.terminationStatus)
        }

        try importFrom(stagingDir: staging, into: account)
    }

    private static func runClaudeLogin(account: Account) throws {
        // Claude 沒有 single-flag login；走 `claude` 互動式登入 with custom CLAUDE_CONFIG_DIR
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-claude-login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["claude"]
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = staging.path
        proc.environment = env

        print("⚠️  Run `/login` inside Claude, then exit (Ctrl+D). orrery will pick up the token.")
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw LoginError.toolExitedNonZero(status: proc.terminationStatus)
        }

        try importFrom(stagingDir: staging, into: account)
    }

    public enum LoginError: Error {
        case missingKeychainItem
        case toolExitedNonZero(status: Int32)
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter AccountLoginFlowTests`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add Sources/OrreryCore/Setup/AccountLoginFlow.swift \
        Tests/OrreryTests/AccountLoginFlowTests.swift
git commit -m "[ADD] AccountLoginFlow: spawn tool login into staging, import to account"
```

---

## Task 15: Phantom `account` subcommand

**Files:**
- Modify: `Sources/OrreryCore/Commands/PhantomCommand.swift`
- Test: `Tests/OrreryTests/PhantomCommandTests.swift`

- [ ] **Step 1: 探勘現有 phantom command**

Run: `grep -n "PhantomCommand" Sources/OrreryCore/Commands/PhantomCommand.swift`

了解現在 phantom command 的 subcommand 結構。如果它本身就是 subcommand pattern（root + sub），加新的 `account` subcommand；如果是單一 command 接受 env 名稱當 argument，要把它改成有兩個 subcommand 的形式。

- [ ] **Step 2: Failing test**

```swift
@Suite("PhantomAccount")
struct PhantomAccountTests {
    var tmpDir: URL!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-phantom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        setenv("ORRERY_HOME", tmpDir.path, 1)
    }

    @Test("emits expected supervisor trigger for account switch")
    func emitsTrigger() throws {
        let acct = Account(tool: .claude, displayName: "switched")
        try AccountStore.default.save(acct)

        var cmd = PhantomAccountSubCommand()
        cmd.name = "switched"

        let output = try captureOutput { try cmd.run() }
        // supervisor 看的觸發字串約定（如已有就沿用既有的）
        #expect(output.contains("_phantom-trigger:account:claude:switched")
             || output.contains("PHANTOM_TRIGGER ACCOUNT claude switched"))
    }
}
```

> 觸發字串的確切格式必須對齊既有 supervisor `activate.sh` 解析的格式——請先 `grep "_phantom-trigger" -r` 確認，並在這個 task 中**同時更新**測試 expected 字串與 supervisor 解析邏輯，讓兩端對齊。

- [ ] **Step 3: Implement**

在 `PhantomCommand.swift` 加入 `PhantomAccountSubCommand`：

```swift
public struct PhantomAccountSubCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "account",
        abstract: "Switch account within current env (in-session)."
    )

    @Flag(name: .long) public var claude: Bool = false
    @Flag(name: .long) public var codex: Bool = false
    @Flag(name: .long) public var gemini: Bool = false

    @Option(name: .long)
    public var name: String

    public init() {}

    public func run() throws {
        let tool = try AccountAddCommand.resolveTool(claude: claude, codex: codex, gemini: gemini)
        // 觸發字串：由 activate.sh supervisor 監聽並重啟工具
        print("_phantom-trigger:account:\(tool.rawValue):\(name)")
    }
}
```

並把它加進 `PhantomCommand` 的 `subcommands` array。如果原本沒有 env 子命令、phantom 是單一指令，請順手做這次重構：把原本的 env-switch 邏輯抽到 `PhantomEnvSubCommand`，root command 變 `phantom` with `account|env` 兩個 sub。

- [ ] **Step 4: 同步更新 activate.sh supervisor**

找 `Sources/OrreryCore/Resources/Scripts/activate.sh`（或對應位置），在 trigger 解析的 switch/case 加入：

```bash
elif [[ "$line" == _phantom-trigger:account:* ]]; then
  # _phantom-trigger:account:<tool>:<name>
  IFS=':' read -ra parts <<< "$line"
  tool="${parts[2]}"
  acct_name="${parts[3]}"
  orrery account use --"$tool" --name "$acct_name"
  # 重啟工具 with --resume <last_session_id>
  ...
fi
```

> 確切 shell 結構依現有檔案調整。Resume session id 沿用既有機制（env switch 已在用）。

- [ ] **Step 5: Run tests**

Run: `swift test --filter PhantomAccountTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/OrreryCore/Commands/PhantomCommand.swift \
        Sources/OrreryCore/Resources/Scripts/activate.sh \
        Tests/OrreryTests/PhantomCommandTests.swift
git commit -m "[ADD] phantom account subcommand + supervisor trigger"
```

---

## Task 16: Version bump, CHANGELOG, badges

**Files:**
- Modify: `Sources/OrreryCore/Commands/OrreryCommand.swift`（`version:` 欄位）
- Modify: `Sources/OrreryCore/MCP/MCPServer.swift`（`currentVersion()`）
- Modify: `Sources/OrreryCore/Version.swift`
- Modify: `CHANGELOG.md`
- Modify: `docs/index.html`、`docs/zh_TW.html`（badge）

- [ ] **Step 1: 決定版號**

主功能新增 → minor bump。檢查目前版號（`grep -rn "version" Sources/OrreryCore/Commands/OrreryCommand.swift | head -3`），設為下一個 minor（例：2.7.0 → 2.8.0）。

- [ ] **Step 2: 更新所有版號位置**

依 CLAUDE.md「Versioning」段：

- `Sources/OrreryCore/Commands/OrreryCommand.swift` 的 `version:` 欄位
- `Sources/OrreryCore/MCP/MCPServer.swift` 的 `currentVersion()` 回傳值
- `Sources/OrreryCore/Version.swift`
- `docs/index.html`、`docs/zh_TW.html` 的 badge URL

- [ ] **Step 3: 更新 CHANGELOG.md**

在頂端加入新版本區塊：

```markdown
## [vX.Y.0] - 2026-MM-DD

### Added
- `orrery account` 系列命令：`add`、`list`、`show`、`use`、`remove`。新使用者不必接觸 env 概念即可切換帳號。
- Accounts pool：`~/.orrery/accounts/<tool>/<id>/`，跨 env 共用憑證。
- `CredentialAdapter`：抽象啟動時憑證 materialize（檔案型 symlink；macOS Claude 走 Keychain 複寫）。
- `orrery phantom account` 子命令，在 session 中切帳號不換 env。
- 自動遷移：首次跑新版時把現有 env 內的憑證抽進 accounts pool，去重，env.json 改用引用；遷移前完整備份到 `~/.orrery-backup-<timestamp>/`。

### Changed
- `OrreryEnvironment` 新增 `accounts: [String: String]` 欄位（Tool.rawValue → AccountID）。
- `orrery run` 啟動前會冪等 materialize 當前 env / origin 釘的 account 憑證。
- `orrery account remove` 仍被任何 env 引用時會擋下並列出引用方。

### Migration Notes
- 自動遷移於首次執行新版時進行；不需手動介入。
- 遷移期間請結束所有 `phantom` session（如果遷移偵測到 supervisor 正在跑會中止並提示）。
- 備份位置：`~/.orrery-backup-<ISO timestamp>/`。
```

- [ ] **Step 4: Run full test suite**

Run: `swift test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Commands/OrreryCommand.swift \
        Sources/OrreryCore/MCP/MCPServer.swift \
        Sources/OrreryCore/Version.swift \
        docs/index.html docs/zh_TW.html \
        CHANGELOG.md
git commit -m "[REL] vX.Y.0: account pool 從 env 拆分"
```

---

## Self-Review Checklist

讀完整份 plan 後檢查：

- [ ] **Spec coverage**: 對照 spec 的第 1～7 節，每節都有對應 task。第 8 節（程式碼變更面）的每個檔案都出現在 File Structure 或 task 中。
- [ ] **No placeholders**: 每個 step 都有具體程式碼或命令；沒有 "implement later"。
- [ ] **Type consistency**: `Account` / `AccountStore` / `CredentialAdapter` / `CredentialAdapters` 在所有 task 中名稱一致。`Tool.rawValue` / `AccountID` 在 model、store、test 中一致使用。
- [ ] **Test framework**: 所有 test 用 `@Suite` + `@Test` + `#expect`（swift-testing），不是 XCTest。
- [ ] **Localization**: 每個會印給使用者的字串都走 `L10n.X.y`，新 key 在 Task 7 統一加入。
- [ ] **Migration backup**: 在實際動到 ~/.orrery/ 內容前先完整 backup。
- [ ] **macOS Keychain**: 所有 Keychain 相關程式碼都 `#if os(macOS)` 包住；adapter factory 對非 macOS 自動降回 Filesystem。

---

## Out of Scope（不在此 plan 內）

- MCP server 新增 account 相關 tools — 待 follow-up plan
- 跨工具 account profile / 一鍵切多工具 — 留待未來
- Account-level memory — spec 已明確排除
- `account rename` — 第一版沒做（使用者用 add+remove 替代）
