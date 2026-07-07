# Fresh-user origin account (all tools) — Design

**Goal:** When a user who has never used Orrery runs it for the first time, their
existing tool config (`~/.claude`, `~/.codex`, `~/.gemini`) becomes the **origin
workspace**, and Orrery creates a brand-new **origin account** per tool that
captures the existing login and links to the workspace. A normal user's account
then holds only its credential/identity — never the shared data — and everything
"just works" without a manual `orrery add`.

**Status:** proposed. All three tools. New installs only (existing installs untouched).

---

## Background — current behavior & the gap

At every invocation `OriginTakeoverBootstrap.runIfNeeded()` calls
`EnvironmentStore.originTakeover(tool:)` for each unmanaged tool whose default
config dir exists: it **moves** `~/.<tool>` → `workspaces/origin/<tool>` (the origin
**workspace**) and symlinks `~/.<tool>` → that workspace dir.

`AccountMigration.enforceOriginClaudeDir` → `repairOriginPins` pins a tool's origin
account **only if one already exists**; `MigrateToV31Command` /
`ClaudeAccountMigration` only bring **existing** accounts to v3.1 layout. **Nothing
creates an origin account.**

**Result for a fresh user (zero accounts):** the login data moves into the workspace
but no account is created:
- **claude**: `~/.claude` stays pointing at the workspace, which has no
  `metadata.json`, so the `claude()` launch wrapper's v3.1 gate is false and Orrery's
  launch hooks never engage. No per-account identity / `.claude.json` / statusline.
- **codex / gemini**: no pool account exists, so `orrery list` shows nothing and
  there is no account to `use` / manage.

This spec fills the gap for all three tools.

## Two account models (both already exist)

- **claude** — per-account-dir model. The account dir *is* `CLAUDE_CONFIG_DIR`;
  shared subdirs are symlinks into the workspace; `~/.claude` → the account dir.
  Credentials: macOS **Keychain** (per-account service `Claude Code-orrery-<id>`);
  identity metadata in `claude-identity.json`.
- **codex / gemini** — pool model. The account dir holds just the credential file
  (`auth.json` / `oauth_creds.json`) + `metadata.json`. `orrery use <acct>`
  materializes that file into `~/.codex` / `~/.gemini` (which → workspace). No
  config-dir switching, no keychain.

## Reusable machinery (do NOT reinvent)

`AccountLoginFlow.importFrom(stagingDir:into:)` already captures a login into a pool
account — it is what `orrery add` uses:
- codex / gemini / Linux-claude: copies the credential file from `stagingDir` into
  the account dir, then refreshes email/plan.
- macOS claude: copies the keychain item `ClaudeKeychain.service(for: stagingDir.path)`
  into the account's own service.

`ClaudeAccountMigration.migrateAccount` then finalizes a claude account (link-only
`prepareDirectory` + seed `claude-identity.json` from the keychain).
`AccountMigration.repointClaudeDirSymlink` repoints `~/.claude` → the account once the
origin pin exists.

## Design

### New step: `seedOriginAccountsIfNeeded(homeURL:)`
Runs from the takeover/enforce flow, **after** `originTakeover` and **before**
`repointClaudeDirSymlink`, iterating all three tools. Tool-generic (not claude-only),
so it replaces the claude-only framing of the earlier draft.

For each tool `T`, run only when **all** hold (idempotent; keeps existing installs
untouched):
1. `loadOriginWorkspace().account(for: T) == nil` — no origin account for `T`.
2. `originTakeover` has run for `T` (`~/.<T>` resolves to the workspace `T` dir).
3. The origin workspace `T` dir exists and contains a credential to capture.

Then:
1. Create `Account(tool: T, displayName: "origin")`; `AccountStore.save`.
2. `AccountLoginFlow.importFrom(stagingDir: <captureSource(T)>, into: account)` —
   reuses the existing per-tool capture.
   - codex / gemini: `captureSource = workspaces/origin/<T>` (holds
     `auth.json` / `oauth_creds.json`).
   - macOS claude: `captureSource` = the path whose `ClaudeKeychain.service(for:)`
     equals the pre-Orrery default service `Claude Code-credentials` (the login the
     user already had). *(Exact path resolved in the plan; `ClaudeKeychain.service`
     defines the mapping.)*
3. Pin: `originWorkspace.setAccount(account.id, for: T)`; save.
4. Tool-specific finalize:
   - **claude**: `ClaudeAccountMigration.migrateAccount` (link-only `prepareDirectory`
     — workspace already holds the data, so pass 1 is a no-op → account is pure
     symlinks; seeds identity). Then `repointClaudeDirSymlink` points `~/.claude` →
     the account dir; `metadata.json` now resolves so the launch wrapper engages.
   - **codex / gemini**: none — the pool account holds the credential; `~/.<T>` stays
     → workspace; `orrery use` materializes on demand.

Best-effort throughout: a per-tool failure logs a warning and never blocks startup or
other tools.

## Edge cases
- **No login present** (`~/.<T>` had no credential) → skip that tool (nothing to
  capture); no empty/broken account.
- **User has non-origin accounts but no origin pin for `T`** → guard #1 is about the
  origin *pin*; if the workspace has `T` data and no origin account, we still create
  one. Rare; acceptable.
- **Re-run / already seeded** → guard #1 (origin account exists) → no-op.
- **Opt-out** (`~/.orrery/.no-origin-takeover`) → whole bootstrap already skipped.
- **claude keychain empty on this machine but `~/.claude.json` has `oauthAccount`** →
  identity seeds from `~/.claude.json` (email only); user re-logs in. No worse than today.

## Testing strategy
- **codex / gemini**: fully automatable — file-based capture, isolated via
  `ORRERY_USER_HOME` + `ORRERY_HOME`. Assert: origin account created, `auth.json` /
  `oauth_creds.json` copied into the account dir, origin pin set, idempotent re-run.
- **claude**: keychain is not isolatable (setting `$HOME` breaks keychain resolution).
  Put keychain access behind a protocol; unit-test the capture with an in-memory fake.
  Unit-test the rest (account create, link-only `prepareDirectory`, `~/.claude`
  repoint) with the existing isolation.
- One **manual** end-to-end on a scratch `ORRERY_HOME`+`ORRERY_USER_HOME` (never the
  real home) for the full three-tool flow.
- Regression: an install that already has origin accounts is left byte-identical.

## Out of scope
- Converging **existing** installs to the fresh shape (decided: leave them).
- Any change to the launch-time mirror (PR #21).

## Resolved decisions
- New account `displayName = "origin"` (matches `findByDisplayName("origin")` /
  `repairOriginPins`).
- Placement: a tool-generic `seedOriginAccountsIfNeeded` invoked from the
  takeover/enforce flow right after `originTakeover`, before `repointClaudeDirSymlink`
  (generalized from the earlier claude-only "put it in `enforceOriginClaudeDir`",
  since codex/gemini are now in scope).
