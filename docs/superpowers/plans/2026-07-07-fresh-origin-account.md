# Fresh-user origin account (all tools) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After origin takeover moves `~/.<tool>` into the origin workspace, auto-create a brand-new "origin" account per tool that captures the existing login and links to the workspace, so a fresh user's account holds only its credential/identity (never shared data) and everything works without a manual `orrery add`.

**Architecture:** One new tool-generic seeder (`OriginAccountSeeder.seedOriginAccountsIfNeeded`) invoked from `main.swift` right before `AccountMigration.enforceOriginClaudeDir`. Per tool with no origin account and a capturable login, it creates the account, captures the login (codex/gemini via `AccountLoginFlow.importFrom` file copy; macOS claude via `ClaudeKeychain.copyKeychainItem` from the default service), pins it to origin, and for claude runs `ClaudeAccountMigration.migrateAccount` (link-only) so the existing `enforceOriginClaudeDir` then repoints `~/.claude`. Keychain access is injected behind a `KeychainAccess` struct so claude is unit-testable with a fake.

**Tech Stack:** Swift, swift-testing (`@Test`/`@Suite`), `ORRERY_USER_HOME`/`ORRERY_HOME` test isolation (via `withIsolatedHome`).

**Branch:** `feat/fresh-origin-account` (already created, spec committed).

---

## File Structure

- Create `Sources/OrreryCore/Setup/KeychainAccess.swift` — tiny injectable seam over `ClaudeKeychain` (existence + copy) so the claude path is testable.
- Create `Sources/OrreryCore/Setup/OriginAccountSeeder.swift` — the seeder (guards, per-tool create/capture/pin, claude finalize).
- Modify `Sources/orrery/main.swift` — call the seeder before `enforceOriginClaudeDir`.
- Create `Tests/OrreryTests/OriginAccountSeederTests.swift` — codex/gemini (real), claude (fake keychain), idempotency, edge cases.

Reused as-is (do not modify): `AccountLoginFlow.importFrom`, `ClaudeAccountMigration.migrateAccount`, `ClaudeKeychain`, `AccountStore`, `EnvironmentStore`, `AccountMigration.enforceOriginClaudeDir`.

---

### Task 1: KeychainAccess seam

**Files:**
- Create: `Sources/OrreryCore/Setup/KeychainAccess.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

/// Injectable seam over the macOS Keychain so origin-account seeding is
/// unit-testable without touching the real login keychain (which cannot be
/// isolated in tests — setting $HOME breaks keychain resolution).
public struct KeychainAccess {
    /// True if a keychain generic-password item exists for `service`.
    public var itemExists: (_ service: String) -> Bool
    /// Copy the item at `from` service to `to` service; returns success.
    public var copyItem: (_ from: String, _ to: String) -> Bool

    public init(
        itemExists: @escaping (_ service: String) -> Bool,
        copyItem: @escaping (_ from: String, _ to: String) -> Bool
    ) {
        self.itemExists = itemExists
        self.copyItem = copyItem
    }

    /// Production wiring — the real Keychain.
    public static let live = KeychainAccess(
        itemExists: ClaudeKeychain.keychainItemExists,
        copyItem: ClaudeKeychain.copyKeychainItem
    )
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build --target OrreryCore 2>&1 | tail -3`
Expected: `Compiling` … no errors. (`ClaudeKeychain.keychainItemExists(service:)` and `copyKeychainItem(from:to:)` already exist and are `public static`.)

- [ ] **Step 3: Commit**

```bash
git add Sources/OrreryCore/Setup/KeychainAccess.swift
git commit -m "[FEAT] KeychainAccess: injectable seam over ClaudeKeychain"
```

---

### Task 2: OriginAccountSeeder — codex/gemini (file-based, fully tested)

**Files:**
- Create: `Sources/OrreryCore/Setup/OriginAccountSeeder.swift`
- Test: `Tests/OrreryTests/OriginAccountSeederTests.swift`

- [ ] **Step 1: Write the failing test (codex + gemini)**

```swift
import Foundation
import Testing
@testable import OrreryCore

@Suite("OriginAccountSeeder")
struct OriginAccountSeederTests {

    /// Simulate post-takeover state: a credential file sitting in the origin
    /// workspace's <tool> dir, and no origin account for that tool yet.
    private func seedWorkspaceCredential(tool: Tool, fileName: String, contents: String) throws {
        let ws = EnvironmentStore.default.originConfigDir(tool: tool)  // workspaces/origin/<tool>
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: ws.appendingPathComponent(fileName))
    }

    @Test("creates a codex origin account capturing auth.json from the workspace")
    func seedsCodex() throws {
        try withIsolatedHome {
            try seedWorkspaceCredential(tool: .codex, fileName: "auth.json", contents: #"{"OPENAI_API_KEY":"x"}"#)

            OriginAccountSeeder.seedOriginAccountsIfNeeded()

            let acctStore = AccountStore.default
            let acct = try #require(try acctStore.findByDisplayName("origin", tool: .codex))
            // credential copied into the account dir
            #expect(FileManager.default.fileExists(
                atPath: acctStore.accountDir(id: acct.id, tool: .codex)
                    .appendingPathComponent("auth.json").path))
            // origin pin set
            #expect(EnvironmentStore.default.loadOriginWorkspace().account(for: .codex) == acct.id)
        }
    }

    @Test("creates a gemini origin account capturing oauth_creds.json")
    func seedsGemini() throws {
        try withIsolatedHome {
            try seedWorkspaceCredential(tool: .gemini, fileName: "oauth_creds.json", contents: #"{"access_token":"x"}"#)

            OriginAccountSeeder.seedOriginAccountsIfNeeded()

            let acctStore = AccountStore.default
            let acct = try #require(try acctStore.findByDisplayName("origin", tool: .gemini))
            #expect(FileManager.default.fileExists(
                atPath: acctStore.accountDir(id: acct.id, tool: .gemini)
                    .appendingPathComponent("oauth_creds.json").path))
            #expect(EnvironmentStore.default.loadOriginWorkspace().account(for: .gemini) == acct.id)
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `env -u CLAUDE_CONFIG_DIR swift test --filter 'seedsCodex|seedsGemini' 2>&1 | tail -15`
Expected: compile error `no member 'seedOriginAccountsIfNeeded'` (type doesn't exist yet).

- [ ] **Step 3: Implement the seeder (codex/gemini path; claude stubbed to skip)**

```swift
import Foundation

/// Fresh-user onboarding: after origin takeover moved `~/.<tool>` into the origin
/// workspace, create a brand-new "origin" account per tool that captures the
/// existing login and pins to the origin workspace — so a normal user's account
/// holds only its credential/identity, never the shared data.
///
/// Idempotent + best-effort. Runs for a tool only when it has NO origin account
/// yet (leaving existing installs untouched) and its origin workspace holds a
/// capturable login. A per-tool failure warns and never blocks startup.
public enum OriginAccountSeeder {

    public static func seedOriginAccountsIfNeeded(keychain: KeychainAccess = .live) {
        let acctStore = AccountStore.default
        let envStore = EnvironmentStore.default
        var origin = envStore.loadOriginWorkspace()

        for tool in Tool.allCases {
            guard origin.account(for: tool) == nil else { continue }   // existing → untouched
            let wsToolDir = envStore.originConfigDir(tool: tool)
            guard hasCapturableLogin(tool: tool, workspaceToolDir: wsToolDir, keychain: keychain)
            else { continue }

            do {
                let id = UUID().uuidString
                let account = Account(
                    id: id, tool: tool, displayName: "origin",
                    keychainItem: tool == .claude
                        ? ClaudeKeychain.serviceName(forOrreryAccount: id) : nil,
                    workspace: Workspace.reservedOriginName)
                try acctStore.save(account)

                try captureLogin(account: account, workspaceToolDir: wsToolDir, keychain: keychain)

                origin.setAccount(id, for: tool)
                try envStore.saveOriginWorkspace(origin)

                if tool == .claude {
                    try ClaudeAccountMigration.migrateAccount(
                        account, accountStore: acctStore, environmentStore: envStore)
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "orrery: could not seed origin \(tool.rawValue) account: \(error)\n".utf8))
            }
        }
    }

    private static func hasCapturableLogin(
        tool: Tool, workspaceToolDir: URL, keychain: KeychainAccess
    ) -> Bool {
        switch tool {
        case .codex, .gemini:
            let f = workspaceToolDir.appendingPathComponent(
                FilesystemCredentialAdapter.credentialFileName(for: tool))
            return FileManager.default.fileExists(atPath: f.path)
        case .claude:
            #if os(macOS)
            return keychain.itemExists(ClaudeKeychain.service(for: nil))
            #else
            return FileManager.default.fileExists(
                atPath: workspaceToolDir.appendingPathComponent(".credentials.json").path)
            #endif
        }
    }

    private static func captureLogin(
        account: Account, workspaceToolDir: URL, keychain: KeychainAccess
    ) throws {
        switch account.tool {
        case .codex, .gemini:
            try AccountLoginFlow.importFrom(stagingDir: workspaceToolDir, into: account)
        case .claude:
            #if os(macOS)
            guard let dst = account.keychainItem,
                  keychain.copyItem(ClaudeKeychain.service(for: nil), dst) else {
                throw AccountLoginFlow.LoginError.credentialNotProduced(.claude)
            }
            #else
            try AccountLoginFlow.importFrom(stagingDir: workspaceToolDir, into: account)
            #endif
        }
    }
}
```

- [ ] **Step 4: Run to verify codex/gemini tests pass**

Run: `env -u CLAUDE_CONFIG_DIR swift test --filter 'seedsCodex|seedsGemini' 2>&1 | grep -E '✔|✘|Test run with'`
Expected: both `✔`, `Test run with 2 tests … passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrreryCore/Setup/OriginAccountSeeder.swift Tests/OrreryTests/OriginAccountSeederTests.swift
git commit -m "[FEAT] OriginAccountSeeder: seed codex/gemini origin accounts from takeover"
```

---

### Task 3: OriginAccountSeeder — claude path (fake keychain)

**Files:**
- Modify: `Tests/OrreryTests/OriginAccountSeederTests.swift` (add tests)

The claude implementation already landed in Task 2's seeder. This task proves it with an injected fake keychain (the real keychain is not isolatable).

- [ ] **Step 1: Write the failing test**

```swift
    @Test("creates a claude origin account: pinned, link-only, ~/.claude untouched by seeder; keychain copied with correct services")
    func seedsClaude() throws {
        try withIsolatedHome {
            let envStore = EnvironmentStore.default
            let acctStore = AccountStore.default
            // Post-takeover: origin workspace claude dir exists (with a shared dir to mirror).
            let wsClaude = envStore.originConfigDir(tool: .claude)  // workspaces/origin/claude
            try FileManager.default.createDirectory(
                at: wsClaude.appendingPathComponent("plugins"), withIntermediateDirectories: true)

            // Fake keychain: pretend the default login exists; record copy calls.
            var copied: [(from: String, to: String)] = []
            let fake = KeychainAccess(
                itemExists: { _ in true },
                copyItem: { from, to in copied.append((from, to)); return true })

            OriginAccountSeeder.seedOriginAccountsIfNeeded(keychain: fake)

            let acct = try #require(try acctStore.findByDisplayName("origin", tool: .claude))
            // pinned to origin
            #expect(envStore.loadOriginWorkspace().account(for: .claude) == acct.id)
            // migrateAccount ran: account dir mirrors the workspace (plugins is a symlink)
            let acctDir = acctStore.accountDir(id: acct.id, tool: .claude)
            #expect((try? FileManager.default.destinationOfSymbolicLink(
                atPath: acctDir.appendingPathComponent("plugins").path))
                == wsClaude.appendingPathComponent("plugins").path)
            // keychain copied from the default service to the per-account service
            #expect(copied.count == 1)
            #expect(copied.first?.from == ClaudeKeychain.service(for: nil))       // "Claude Code-credentials"
            #expect(copied.first?.to == ClaudeKeychain.serviceName(forOrreryAccount: acct.id))
        }
    }
```

- [ ] **Step 2: Run to verify it passes (implementation already present)**

Run: `env -u CLAUDE_CONFIG_DIR swift test --filter 'seedsClaude' 2>&1 | grep -E '✔|✘|Test run with'`
Expected: `✔`, `Test run with 1 test … passed`.

Note on the `plugins` mirror assertion: `migrateAccount` → `prepareDirectory` → `linkAccountDirsToWorkspace`, whose second pass (`mirrorWorkspaceDirsToAccount`, shipped in PR #21 / merged) symlinks the workspace's `plugins` into the fresh account. If PR #21 is NOT yet merged into this branch's base, rebase onto it first, or weaken this assertion to check the base-5 (`projects`) symlink instead.

- [ ] **Step 3: Commit**

```bash
git add Tests/OrreryTests/OriginAccountSeederTests.swift
git commit -m "[TEST] OriginAccountSeeder: claude path with injected keychain"
```

---

### Task 4: Idempotency + edge cases

**Files:**
- Modify: `Tests/OrreryTests/OriginAccountSeederTests.swift` (add tests)

- [ ] **Step 1: Write the failing tests**

```swift
    @Test("no capturable login → no account created")
    func skipsWhenNoLogin() throws {
        try withIsolatedHome {
            // No workspace credential files, fake keychain reports no login.
            let fake = KeychainAccess(itemExists: { _ in false }, copyItem: { _, _ in false })
            OriginAccountSeeder.seedOriginAccountsIfNeeded(keychain: fake)
            #expect((try AccountStore.default.findByDisplayName("origin", tool: .codex)) == nil)
            #expect((try AccountStore.default.findByDisplayName("origin", tool: .claude)) == nil)
        }
    }

    @Test("existing origin account → no-op (idempotent, existing installs untouched)")
    func skipsWhenOriginAccountExists() throws {
        try withIsolatedHome {
            let envStore = EnvironmentStore.default
            let acctStore = AccountStore.default
            // Pre-existing origin codex account + pin.
            let existing = Account(tool: .codex, displayName: "origin")
            try acctStore.save(existing)
            var origin = envStore.loadOriginWorkspace()
            origin.setAccount(existing.id, for: .codex)
            try envStore.saveOriginWorkspace(origin)
            // A workspace credential is present, but the pin already exists.
            let ws = envStore.originConfigDir(tool: .codex)
            try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: ws.appendingPathComponent("auth.json"))

            OriginAccountSeeder.seedOriginAccountsIfNeeded()

            // Still exactly one codex account, and the pin is unchanged.
            #expect(try acctStore.list(tool: .codex).count == 1)
            #expect(envStore.loadOriginWorkspace().account(for: .codex) == existing.id)
        }
    }

    @Test("running twice creates the account only once")
    func idempotentAcrossRuns() throws {
        try withIsolatedHome {
            let ws = EnvironmentStore.default.originConfigDir(tool: .codex)
            try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: ws.appendingPathComponent("auth.json"))

            OriginAccountSeeder.seedOriginAccountsIfNeeded()
            OriginAccountSeeder.seedOriginAccountsIfNeeded()

            #expect(try AccountStore.default.list(tool: .codex).count == 1)
        }
    }
```

- [ ] **Step 2: Run to verify they pass**

Run: `env -u CLAUDE_CONFIG_DIR swift test --filter 'skipsWhenNoLogin|skipsWhenOriginAccountExists|idempotentAcrossRuns' 2>&1 | grep -E '✔|✘|Test run with'`
Expected: 3 `✔`. (If `skipsWhenOriginAccountExists` fails because a codex login was captured, verify the guard `origin.account(for: tool) == nil` short-circuits before `captureLogin`.)

- [ ] **Step 3: Commit**

```bash
git add Tests/OrreryTests/OriginAccountSeederTests.swift
git commit -m "[TEST] OriginAccountSeeder: idempotency + no-login/existing-account guards"
```

---

### Task 5: Wire into the bootstrap

**Files:**
- Modify: `Sources/orrery/main.swift` (call site is line 39, `AccountMigration.enforceOriginClaudeDir(homeURL: orreryHomeURL())`)

- [ ] **Step 1: Read the current bootstrap block**

Run: `sed -n '1,45p' Sources/orrery/main.swift`
Expected: shows `OriginTakeoverBootstrap.runIfNeeded()` (line 17) then, near line 39, `AccountMigration.enforceOriginClaudeDir(homeURL: orreryHomeURL())`.

- [ ] **Step 2: Insert the seeder call immediately before `enforceOriginClaudeDir`**

Edit `Sources/orrery/main.swift` — add the line directly above the `enforceOriginClaudeDir` call:

```swift
    // Fresh-user onboarding: after takeover moved ~/.<tool> into the origin
    // workspace, create a link-only origin account per tool (no-op if one exists).
    // Must run BEFORE enforceOriginClaudeDir so the claude pin exists for the
    // ~/.claude repoint below.
    OriginAccountSeeder.seedOriginAccountsIfNeeded()
    AccountMigration.enforceOriginClaudeDir(homeURL: orreryHomeURL())
```

- [ ] **Step 3: Build**

Run: `swift build --product orrery-bin 2>&1 | tail -3`
Expected: `Build … complete!` no errors.

- [ ] **Step 4: Full suite (safe — isolation via ORRERY_USER_HOME)**

Run: `env -u CLAUDE_CONFIG_DIR swift test 2>&1 | grep -E '✘|Test run with' | tail -5`
Expected: `Test run with … passed` (no `✘`).

- [ ] **Step 5: Commit**

```bash
git add Sources/orrery/main.swift
git commit -m "[FEAT] bootstrap seeds origin accounts before enforcing ~/.claude"
```

---

### Task 6: Manual end-to-end verification (scratch home — never the real home)

**Files:** none (verification only). This exercises the real keychain, which the suite cannot.

- [ ] **Step 1: Build the binary**

Run: `swift build --product orrery-bin 2>&1 | tail -1`

- [ ] **Step 2: Run the whole flow against an isolated scratch home**

```bash
BIN="$PWD/.build/debug/orrery-bin"
SBX="$(mktemp -d)"
# Fake a codex login in a fake HOME's default config dir, then take over + seed.
export ORRERY_HOME="$SBX/orrery" ORRERY_USER_HOME="$SBX/home"
mkdir -p "$SBX/home/.codex"
printf '{"OPENAI_API_KEY":"test"}' > "$SBX/home/.codex/auth.json"
env -u CLAUDE_CONFIG_DIR "$BIN" list        # triggers takeover + seeder
echo "--- codex origin account created? ---"
env -u CLAUDE_CONFIG_DIR "$BIN" list | grep -A2 'codex accounts'
echo "--- account dir has auth.json? ---"
ls "$ORRERY_HOME"/accounts/codex/*/auth.json
rm -rf "$SBX"
```

Expected: `list` shows a `codex` account named `origin`; the account dir contains `auth.json`. (No touch to the real `~/.codex` — `ORRERY_USER_HOME` isolates `Tool.defaultConfigDir`.)

- [ ] **Step 2b (macOS claude, optional real-keychain check):** only if you have a scratch claude login to spare — otherwise rely on the fake-keychain unit test. Do NOT run against your real login keychain.

- [ ] **Step 3: No commit** (verification only). Record the result in the PR description.

---

## Self-Review

**Spec coverage:**
- Fresh account per tool + capture login → Tasks 2 (codex/gemini) + 3 (claude). ✓
- Guards (no origin account; capturable login) → Task 2 impl + Task 4 tests. ✓
- claude finalize (link-only prepare + `~/.claude` repoint) → Task 2 (`migrateAccount`) + Task 5 (`enforceOriginClaudeDir` after seeder). ✓
- Idempotency / existing installs untouched → Task 4. ✓
- Keychain testability seam → Task 1. ✓
- Manual e2e → Task 6. ✓
- Out of scope (existing-install convergence, launch mirror) → not touched. ✓

**Placeholder scan:** none — every code step is complete. Task 3's note about PR #21 is a real rebase precondition, not a placeholder.

**Type consistency:** `seedOriginAccountsIfNeeded(keychain: KeychainAccess = .live)`, `KeychainAccess.{itemExists,copyItem}`, `ClaudeKeychain.service(for:)` / `serviceName(forOrreryAccount:)` / `keychainItemExists` / `copyKeychainItem`, `Account(id:tool:displayName:keychainItem:workspace:)`, `Workspace.setAccount(_:for:)` / `account(for:)`, `EnvironmentStore.originConfigDir(tool:)`, `AccountStore.findByDisplayName(_:tool:)` / `accountDir(id:tool:)` / `list(tool:)`, `AccountLoginFlow.importFrom(stagingDir:into:)`, `ClaudeAccountMigration.migrateAccount(_:accountStore:environmentStore:)` — all match the current APIs verified in the source.

**Dependency note:** Task 3's `plugins`-mirror assertion depends on PR #21 (`mirrorWorkspaceDirsToAccount`) being in this branch's base. Rebase `feat/fresh-origin-account` onto `main` after #21 merges, or use the base-5 (`projects`) symlink in that assertion.
