# Keychain test isolation — Design

**Goal:** Stop the test suite from writing to the developer's real macOS login
Keychain. A full `swift test` currently adds ~12 stray `Claude Code-orrery-*`
items per run (≈2900 had accumulated). Route the two production keychain **write**
paths through the injectable `KeychainAccess` seam so the polluting tests inject a
fake and never touch the real Keychain.

**Status:** proposed. Test-isolation refactor; no user-facing behavior change
(production keeps `.live`). Branch `feat/keychain-test-isolation`.

---

## Root cause

The macOS login Keychain is global — `ORRERY_HOME`/`ORRERY_USER_HOME` do not scope
it, and setting `$HOME` breaks Keychain resolution. Two production write primitives
run against the real default service `Claude Code-credentials` when tests exercise
them:

- `ClaudeKeychain.copyKeychainItem` — via `AccountLoginFlow.importFrom` (macOS
  claude). Hit by `AccountLoginFlowTests` (macOS claude test) and the
  `AccountAddFinalize` "v3.1 layout" test (`AccountCommandsTests`).
- `ClaudeKeychain.storePassword` — via `AccountMigration.copyCredentialIntoPool`
  ← `AccountMigration.migrateAccount(tool:…)` (the v3.0.4→pool credential path).

`ClaudeKeychainTests` only tests `service(for:)` (pure string derivation) — no I/O,
does not pollute. Read paths (`password(forService:)`, `keychainItemExists`) don't
pollute (a miss is harmless), so they stay direct — only writes are seamed (YAGNI).

## Design

Extend the existing `KeychainAccess` seam (added in PR #22 — currently `itemExists`
+ `copyItem`) with the second write primitive:

```swift
public var storePassword: @Sendable (_ password: String, _ accountID: String) -> Bool
```

`.live.storePassword = ClaudeKeychain.storePassword(_:forOrreryAccount:)`.

Thread a `keychain: KeychainAccess = .live` parameter through the two write paths and
their callers; production omits it (`.live`), tests pass a fake:

| Production symbol | change |
|---|---|
| `AccountLoginFlow.importFrom(stagingDir:into:)` | add `keychain: KeychainAccess = .live`; macOS-claude branch uses `keychain.copyItem` instead of `ClaudeKeychain.copyKeychainItem` |
| `AccountMigration.migrateAccount(tool:…)` + `copyCredentialIntoPool` | add `keychain: KeychainAccess = .live`; use `keychain.storePassword` instead of `ClaudeKeychain.storePassword` |
| `AccountAddFinalizeCommand` | thread `.live` through to `importFrom` (+ `migrateAccount` if it calls the tool-level one); a test can inject via an internal seam if needed |
| `OriginAccountSeeder` | already holds a `KeychainAccess` — pass it to `importFrom` (was calling the no-arg form) |

## Tests to convert (inject a fake, assert no real-Keychain touch)

- `AccountLoginFlowTests` macOS-claude test → inject a recording fake for `copyItem`.
- `AccountCommandsTests` `AccountAddFinalize` "v3.1 layout" test → inject a fake so
  `importFrom` (and any `migrateAccount`) never write the real Keychain.
- Any test calling `AccountMigration.migrateAccount(tool:…)` → inject a fake.
- New guard test: run the seeder/import/finalize with a fake and assert the fake's
  recorded calls (not the real Keychain).

**Isolation regression check:** the manual step from PR #22 (count
`Claude Code-orrery-*` before/after a full `swift test`) must show **no growth**.
Codex/gemini paths are already file-based and unaffected.

## Out of scope
- Read-path seaming (harmless; YAGNI).
- `ClaudeKeychainTests` (no I/O).
- Any production behavior change (`.live` everywhere in prod).

## Open question
- Whether `AccountAddFinalizeCommand` needs an injectable entry point for its test,
  or whether the test can drive `AccountLoginFlow.importFrom(…, keychain:)` +
  `migrateAccount(…, keychain:)` directly. Prefer the latter (no command-level
  plumbing) if the finalize test can be reframed around the two seam-aware calls.
