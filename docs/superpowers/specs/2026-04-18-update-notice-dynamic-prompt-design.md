# Dynamic Update Notice — Design Spec

**Status:** Draft (pending user review)
**Date:** 2026-04-18
**Scope:** Orrery CLI

## Motivation

`orrery _check-update` currently prints a fixed one-liner when a newer release exists. Some upgrade paths need more than that — for example, users on versions earlier than a certain release may need to reinstall via a different method rather than `brew upgrade`. Embedding those warnings in the binary means we'd have to ship a new release just to warn users about the old ones.

Goal: give maintainers a way to publish a short dynamic notice that appears alongside the existing update notification, without touching the binary.

## Non-goals

- No rich formatting / markdown rendering — plain text is enough.
- No notice on every command, only when an update is already being advertised.
- No notice during `orrery update` itself (we don't want to interleave with the install script's output).
- No per-version notice files. A single rolling file.
- No user-facing configuration (URL is hardcoded in the binary).

## High-level flow

1. `_check-update` fetches the latest GitHub release (existing logic unchanged).
2. If `latest == current`, return immediately. **No notice fetch happens.**
3. Otherwise, print the existing `L10n.Update.notice(...)` line.
4. Then call `UpdateNoticeFetcher.fetch(currentVersion:)`. If it returns a non-nil string, print a blank line and the body.
5. `_check-update` is invoked at most once every 4 hours by the shell wrapper (existing throttle in `ShellFunctionGenerator.swift:24`), so the fetch rate is naturally bounded. No additional throttling needed.

## Remote notice file

- **URL:** `https://raw.githubusercontent.com/OffskyLab/Orrery/main/docs/update-notice.md`
- **Branch:** `main` (not a tag) — notices must be publishable without cutting a release.
- **Expected size:** small (< 64 KB enforced on the client).

### Format

```markdown
---
applies-to: <2.3.0
---
**Important:** If you're upgrading from a version earlier than 2.3.0,
please reinstall via the install script instead of `brew upgrade`.
See: https://…
```

### Header rules

- YAML-lite: hand-parsed line-by-line, no external parser.
- Only `applies-to` is recognized. Other keys are ignored.
- Operators supported: `<`, `<=`, `=`, `>=`, `>`.
- Comma-separated list forms a logical AND: `>=2.0.0, <2.3.0`.
- **Missing header or missing `applies-to` → notice is not shown** (fail-closed). This is intentional: an unscoped notice likely means the maintainer forgot to set a range.
- **Header parse failure → notice is not shown** for this run. Nothing is written to stderr.

### Body rules

- Everything after the closing `---` is treated as body.
- Printed verbatim; no markdown rendering.
- Authors should pre-wrap lines to ≈ 80 columns.

### Version comparison

- Custom `SemanticVersion` value type, supports only `MAJOR.MINOR.PATCH`.
- Suffixes like `-beta` are stripped before parsing.
- Unparseable current version is treated as `0.0.0`.

## Components

All new code lives under `Sources/OrreryCore/Update/`:

| Type | Responsibility |
|---|---|
| `UpdateNoticeFetcher` | Orchestrates: load cache → conditional GET → parse → apply-to check → return `String?`. Never throws. |
| `UpdateNotice` | Value type. `appliesTo: [VersionConstraint]`, `body: String`. Has `parse(_ raw: String) -> UpdateNotice?` and `applies(to currentVersion: SemanticVersion) -> Bool`. |
| `VersionConstraint` | `(op: Operator, version: SemanticVersion)`. Five operators. |
| `SemanticVersion` | Lightweight `MAJOR.MINOR.PATCH`, `Comparable`. |
| `NoticeCache` (file-private) | Reads/writes `$ORRERY_HOME/.update-notice-cache.json`. |

Modified:

| File | Change |
|---|---|
| `Sources/OrreryCore/Commands/CheckUpdateCommand.swift` | In the `latest != current` branch, after the existing `print(...)`, call the fetcher and append its output when non-nil. |

No changes to `UpdateCommand`, `ShellFunctionGenerator`, or `UninstallCommand` — cache lives under `$ORRERY_HOME` which is already cleaned as a whole by install/uninstall scripts.

## Cache

**Path:** `$ORRERY_HOME/.update-notice-cache.json`

**Schema:**

```json
{
  "etag": "W/\"abc123…\"",
  "body": "markdown body without header",
  "applies_to": "<2.3.0",
  "fetched_at": 1734567890
}
```

We store the parsed body and the raw `applies-to` string so a 304 cache hit doesn't need to re-parse a full file. `fetched_at` is informational only (not consulted for TTL — there is no TTL).

## HTTP flow

Uses `curl` for consistency with existing `CheckUpdateCommand`. No `URLSession`.

Request shape:

```sh
curl -sf --max-time 5 \
  -w '%{http_code}' \
  -o <tmpfile> \
  -H 'User-Agent: orrery-cli' \
  -H 'If-None-Match: <etag-if-cached>' \
  https://raw.githubusercontent.com/OffskyLab/Orrery/main/docs/update-notice.md
```

Status code is captured from stdout; body is read from `<tmpfile>` (so it's clean of curl's own output).

### Outcome matrix

| HTTP / curl outcome | Action on cache | Output |
|---|---|---|
| 200 (size ≤ 64 KB, parse OK, `applies-to` matches) | Write new cache | Print body |
| 200 but `applies-to` doesn't match | Write new cache | No output |
| 200 but parse fails or > 64 KB | Don't touch cache | No output |
| 304 (we had ETag) | Keep existing cache | Print cached body if `applies-to` matches |
| 404 | **Delete cache** (file genuinely gone) | No output |
| Other 4xx / 5xx | Keep cache | Print cached body if matches |
| curl fail / timeout / non-zero exit | Keep cache | Print cached body if matches |

## Error handling principles

- Fetcher always returns `String?`, never throws out.
- Never writes to stderr, never changes exit code, never breaks the background `_check-update` run captured by the shell wrapper.
- Absent / unwritable `$ORRERY_HOME` → skip cache entirely, do a plain GET; still never crashes.
- CI / offline / sandboxed environments → equivalent to curl-failure path.

## Output shape

```
Update available: 2.2.1 → 2.4.0          ← existing L10n.Update.notice

<dynamic notice body, printed verbatim>    ← only if fetcher returned non-nil
```

Single blank line separator between the two blocks. No color / no ANSI escapes added by the fetcher — the existing shell wrapper already wraps `.update-notice` contents in yellow (`ShellFunctionGenerator.swift:16`).

## Testing

New file: `Tests/OrreryTests/UpdateNoticeFetcherTests.swift`. No real network I/O.

### Pure parsing

- `UpdateNotice.parse`: valid header, missing header, missing `applies-to`, bad operator, multiple `---` in body (must not confuse frontmatter detection), Windows-style line endings.
- `SemanticVersion`: `2.4.0`, `2.4.0-beta`, `2.4` (invalid — 3 components required), arbitrary junk.
- `UpdateNotice.applies(to:)`: each operator at boundary values, comma-AND, empty constraint list.

### Cache layer

- Round-trip write/read using `FileManager.default.temporaryDirectory`.
- Corrupt JSON on disk → `read` returns nil, does not throw.
- Body > 64 KB → `write` rejects.

### Fetcher with injected transport

`UpdateNoticeFetcher` takes a `fetch: (URL, String?) -> FetchResult` closure. Production wires curl; tests wire a fake.

```swift
enum FetchResult {
    case ok(etag: String?, body: String)
    case notModified
    case gone          // 404
    case failed        // timeout / network / other 5xx
}
```

Test matrix:

- First run, `.ok` → cache written, body returned if `applies-to` matches
- `.ok` with non-matching `applies-to` → cache written, nil returned
- `.notModified` → uses cached body (if matches), cache unchanged
- `.failed` + cache present → returns stale cached body (if matches)
- `.failed` + no cache → nil, no file created
- `.gone` → cache deleted, nil returned
- `.ok` with parse failure → cache untouched, nil returned

### Not tested

- Real HTTP to GitHub (manual / CI smoke test).
- `CheckUpdateCommand` end-to-end plumbing (mirrors existing style — no tests for that file today).

## Rollout

1. Land the code + tests.
2. Commit a placeholder `docs/update-notice.md` with `applies-to: <0.0.1` (matches nobody, so it's a no-op until we're ready to announce something).
3. When the first real notice is needed, edit that file on `main` and push. Active users see it within 4 hours of their next shell command.

## Open risks

- If a maintainer pushes a malformed notice file, users silently see nothing — we have no telemetry to know. Mitigation: document the format in repo-level CONTRIBUTING or inline comment at top of the notice file.
- `raw.githubusercontent.com` is not guaranteed forever; if it ever stops serving, the fallback keeps working (curl-fail path), just without fresh content. Acceptable.
