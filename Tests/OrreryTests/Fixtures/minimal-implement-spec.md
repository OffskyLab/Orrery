# Minimal implement fixture

This file is a test fixture used by `SpecImplementCommandTests` and by the
CLI smoke assertions in the implement MVP spec. It is intentionally minimal:
it contains the four mandatory headings DI5 requires, plus a single trivial
acceptance command that succeeds in any working directory.

## 來源

N/A — synthetic fixture.

## 目標

Exercise the `orrery spec-run --mode implement` happy path without needing
a real codebase change.

## 介面合約

No real API; this is a no-op fixture. A delegate reading this spec should
skip immediately and emit the required summary structure.

```swift
// placeholder — nothing to implement
```

## 改動檔案

| File | Change |
| --- | --- |
| *(none — fixture spec)* | no-op |

## 實作步驟

1. Read this spec.
2. Skip (no real changes required).
3. Emit the required `## Touched files` and `## Completed steps` sections.

## 失敗路徑

If the delegate cannot emit the summary, write a `skip` event to the
progress log and exit 0.

## 不改動的部分

Everything. This is a fixture.

## 驗收標準

- [ ] The implement runner returns a `status=running` JSON with a non-nil `session_id` and a well-formed schema.
- [ ] The session state file at `~/.orrery/spec-runs/{session_id}.json` exists after implement returns.

```bash
echo fixture-ok
```
