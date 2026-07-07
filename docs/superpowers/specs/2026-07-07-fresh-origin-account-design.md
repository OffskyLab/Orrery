# Fresh-user origin account — Design

**Goal:** When a user who has never used Orrery runs it for the first time, their
existing `~/.claude` becomes the **origin workspace**, and Orrery creates a
brand-new **link-only origin account** pinned to that workspace, with `~/.claude`
pointing at the account. A normal user's account then holds only identity + private
files + symlinks into the workspace — never real shared data.

**Status:** proposed. Claude-only. New installs only (existing installs untouched).

---

## Background — current behavior & the gap

At every invocation, `OriginTakeoverBootstrap.runIfNeeded()` calls
`EnvironmentStore.originTakeover(tool:)` for each unmanaged tool whose default
config dir exists:

- `originTakeover(.claude)` **moves** `~/.claude` → `workspaces/origin/claude`
  (the origin **workspace**) and symlinks `~/.claude` → that workspace dir.
- `AccountMigration.enforceOriginClaudeDir` → `repairOriginPins` pins the origin
  workspace's per-tool account **only if one already exists** (by displayName
  "origin"); `repointClaudeDirSymlink` repoints `~/.claude` → the origin **account**
  dir **only if that pin exists**.

`MigrateToV31Command` / `ClaudeAccountMigration.migrateAccount` bring **existing**
accounts (`AccountStore.list`) up to the v3.1 per-account-dir layout. Nothing
**creates** an origin account.

**Result for a fresh user (zero accounts):** data moves into the workspace, but no
origin account is created, so `~/.claude` stays pointing directly at the workspace.
That dir has no `metadata.json`, so the `claude()` launch wrapper's v3.1 gate
(`[ -f "$HOME/.claude/metadata.json" ]`) is false and Orrery's launch hooks never
run. There is no per-account identity / `.claude.json` / statusline cache layer.

This spec fills that gap.

## Login/credential facts (macOS)

- `~/.claude.json` (home file, **not** inside the `~/.claude` dir, so `originTakeover`
  does **not** move it) holds `oauthAccount` (email, `subscriptionType`).
- The macOS **Keychain** holds the actual tokens under the default service
  `Claude Code-credentials` (JSON with `claudeAiOauth.{accessToken,refreshToken,…}`).
- A v3.1 account stores its credentials under a **per-account** keychain service
  named `Claude Code-orrery-<accountID>` (see `Account.keychainItem`) and seeds
  `claude-identity.json` `oauthAccount` from that service (see
  `ClaudeAccountMigration.migrateAccount`).

So a fresh account is only "logged in" if we copy the default-service credentials
into its per-account service **and** seed its identity file.

## Design

### Trigger & guards
Add a claude-only step to the origin-takeover/enforce flow (after
`originTakeover(.claude)`), guarded so it runs at most once and never for existing
installs:

- Run only when **all** hold:
  1. `loadOriginWorkspace().account(for: .claude) == nil` — no origin claude account
     (this alone keeps every existing install untouched).
  2. `~/.claude` currently resolves to the origin **workspace** claude dir
     (i.e. the takeover just happened / hasn't been converted to an account).
  3. The origin workspace claude dir exists.

### Steps (all idempotent / best-effort — never block startup)
1. **Create** `Account(tool: .claude, displayName: "origin")`; `AccountStore.save`.
2. **Capture the login** into the new account (see below).
3. **Pin** it: `originWorkspace.setAccount(newID, for: .claude)`; save.
4. **prepareDirectory(account:)** — the workspace already holds the data, so pass 1
   (account→workspace migrate) is a no-op and the account becomes pure symlinks
   into the workspace (the "link-only" account). This reuses existing, tested code.
5. Let the existing `repointClaudeDirSymlink` point `~/.claude` → the new account dir
   (it fires once the origin pin exists). `~/.claude/metadata.json` now resolves, so
   the launch wrapper engages normally.

### Credential capture (the crux)
`captureOriginLogin(into: Account)`:
- Read default keychain service `Claude Code-credentials` → if present, write the
  same JSON to the account's per-account service `Claude Code-orrery-<id>`.
  (Do **not** delete the default service — leaves the pre-Orrery state recoverable.)
- Seed `claude-identity.json` `oauthAccount`: prefer the full `claudeAiOauth` from
  the captured keychain creds; else fall back to `oauthAccount` read from
  `~/.claude.json`; else empty `{}` (user re-logs in — no worse than today).

## Edge cases
- **`~/.claude` empty / no login** → still create the account (or skip if no data);
  identity seeds to `{}`; user logs in normally. No crash.
- **User already has non-origin accounts but no origin pin** → guard #1 fires only on
  a missing origin *pin*; if the workspace has data and no origin account, we still
  create one. (Rare; acceptable.)
- **Re-run** → guard #1 (origin account now exists) makes it a no-op.
- **Opt-out** (`~/.orrery/.no-origin-takeover`) → whole bootstrap already skipped.
- **codex / gemini** → out of scope. They have no per-account-dir model in v3.1
  (`~/.codex`/`~/.gemini` → workspace dirs directly); unchanged.

## Testing strategy
- **Keychain is not isolatable** in the suite (it's the real macOS keychain; setting
  `$HOME` to isolate breaks keychain resolution — established earlier). So:
  - Inject keychain access behind a small protocol (wrap `ClaudeKeychain`); unit-test
    `captureOriginLogin` with an in-memory fake (default-service creds in → per-account
    service + identity file out).
  - Unit-test account creation + pin + link-only `prepareDirectory` + `~/.claude`
    repoint using the existing `ORRERY_USER_HOME` isolation (no keychain needed).
  - One **manual** end-to-end verification on a scratch `ORRERY_HOME`+`ORRERY_USER_HOME`
    (never the real home) confirming the whole flow.
- Regression guard: an install that already has an origin account is left byte-identical.

## Out of scope
- Converging **existing** installs to the fresh-account shape (decided: leave them).
- codex / gemini origin accounts.
- Any change to the launch-time mirror (that's PR #21).

## Open questions
- Should the new account's `displayName` be `origin` (matches the existing convention
  `repairOriginPins`/`findByDisplayName("origin")` rely on) — assumed **yes**.
- Where exactly to place the new step: inside `AccountMigration.enforceOriginClaudeDir`
  (before `repointClaudeDirSymlink`) vs a new function called from
  `OriginTakeoverBootstrap`. Leaning `enforceOriginClaudeDir` since it already owns
  origin-pin repair and runs right after takeover.
