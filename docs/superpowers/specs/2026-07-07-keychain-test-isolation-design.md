# Keychain test isolation — Design

**Goal:** Stop the test suite from leaving stray credentials in the developer's
real macOS login Keychain. ~2900 `Claude Code-orrery-*` items had accumulated and
a full `swift test` added ~7 per run.

**Approach: test-side cleanup only — NO production changes.** This is a test-only
problem (production keychain writes are correct and necessary for real logins), so
it is fixed entirely in the test harness. An earlier draft proposed routing
production keychain writes through an injectable `KeychainAccess` seam; that was
**rejected** — it would churn production signatures for a test-only concern.

**Status:** implemented (branch `feat/keychain-test-isolation`). No production code
touched.

---

## Root cause

The macOS login Keychain is **global** — `ORRERY_HOME` / `ORRERY_USER_HOME` do not
scope it, and setting `$HOME` breaks Keychain resolution. So a test that exercises a
claude keychain **write** against the real default service `Claude Code-credentials`
creates a stray per-account item (`Claude Code-orrery-<uuid>`) in the real keychain.

Primary offender: `AccountMigrationTests` → `AccountMigration.runIfNeeded` →
`migrateOrigin(.claude)` → `extractCredential(isOrigin:)` reads the real
`Claude Code-credentials` and `storePassword`s a copy under a new per-account
service — even though the test's home is isolated (the keychain isn't). ~7/run.

`ClaudeKeychainTests` only test `service(for:)` (pure string logic — no I/O). The
known claude keychain tests (`AccountLoginFlow` macOS, `AccountAddFinalize` v3.1)
already clean up via `KeychainTestSupport.delete`.

## Fix (test-only)

`Tests/OrreryTests/TestHelpers.swift`: add

```swift
func sweepClaudeKeychain(home: URL) {
    #if os(macOS)
    for acct in (try? AccountStore(homeURL: home).list(tool: .claude)) ?? [] {
        for service in Set([ClaudeKeychain.serviceName(forOrreryAccount: acct.id),
                            acct.keychainItem].compactMap { $0 }.filter { !$0.isEmpty }) {
            // security delete-generic-password -s <service>  (matches any account field)
        }
    }
    #endif
}
```

Deletes each isolated claude account's per-account keychain service (the
deterministic `serviceName(forOrreryAccount:)` even when `metadata.keychainItem`
was never persisted, plus any explicit `keychainItem`), by service name.

Call it from the teardown of both isolated-home helpers, before the temp home is
removed:
- `withIsolatedHome` defer (covers unit tests).
- `AccountMigrationTests.makeTempHome` cleanup (covers the migration suite — the
  primary offender, which uses its own temp home).

## Verification

Manual before/after check (from the PR #22 pattern): count unique
`Claude Code-orrery-*` services before and after a full `swift test`. Result:
**per-run growth reduced from ~7 to ~1**; backlog cleaned (~2894 → 7 legit).

## Residual (open)

A stubborn **~1/run** remains from a source not identifiable by static analysis
(all known writers clean up; `PhantomTriggerTests` uses a shell *stub* not the real
binary; migration-read tests have no `keychainItem`). Pinning it needs **runtime
instrumentation**: temporarily print a stack trace inside `ClaudeKeychain`'s write
functions (`copyKeychainItem` / `storePassword` / `addPassword`), run the suite,
read the offending caller, revert the instrumentation, and add cleanup there.
Tracked as a focused follow-up.

## Out of scope
- Any production change (rejected — test-only concern).
- Read-path handling (a keychain read miss is harmless).
- `ClaudeKeychainTests` (no I/O).
