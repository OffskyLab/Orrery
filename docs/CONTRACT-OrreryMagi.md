# `OrreryMagi` — Public Surface Contract

**Status**: Phase 2 Step 4 (sidecar mandatory; in-process fallback removed) — 2026-04-27
**Go/No-Go review for Phase 3 (independent repo release)**: **2026-07-01**

This document is the authoritative contract for the `OrreryMagi` library
target shipped in this repo. After Phase 2 Step 4 the library is a thin
shim: it exposes the `magi` CLI shell, the `orrery_magi` MCP tool, and
the sidecar handshake — but it no longer contains in-process Magi
orchestration. Orchestration ships in the sibling `orrery-magi`
repository as a standalone binary, which this shim delegates to via
subprocess.

---

## Direct public surface (what `OrreryMagi` consumes from `OrreryCore`)

These types / symbols are `public` on `OrreryCore` **because** `OrreryMagi`
depends on them. Removing or renaming any of these is a breaking change
for `OrreryMagi` and requires a coordinated bump.

### Tool + session model
- `enum Tool` (claude / codex / gemini) — wire format; `rawValue` is
  used in file paths and MCP payloads.
- `struct SessionEntry` (`id`, `firstMessage`, `lastTime`, `userCount`).
- `enum SessionResolver`
  - `static func findScopedSessions(tool:cwd:store:activeEnvironment:) -> [SessionEntry]`
  - `static func resolve(_:tool:cwd:store:activeEnvironment:)` (used by the
    delegate-resume UX; not strictly Magi, but co-located).

### Executor abstraction (DI12)
- `protocol AgentExecutor`
  - `func execute(request: AgentExecutionRequest) throws -> AgentExecutionResult`
  - `func cancel()` (idempotent; fire-and-forget)
- `struct AgentExecutionRequest` — `tool`, `prompt`, `resumeSessionId?`,
  `timeout`, `metadata: [String: String]`.
- `struct AgentExecutionResult` — `tool`, `rawOutput`, `stderrOutput`,
  `exitCode`, `timedOut`, `sessionId?`, `duration`, `metadata`.
- `final class ProcessAgentExecutor: AgentExecutor` — concrete
  conformance; wraps `DelegateProcessBuilder` + `SessionResolver`.

### Environment + storage
- `class EnvironmentStore`
  - `static var `default``
  - `var homeURL: URL`
  - `func sharedSessionDir(tool:) -> URL`
  - `func toolConfigDir(tool:environment:) -> URL`
  - `func listNames() throws -> [String]`
- `enum ReservedEnvironment` — `defaultName` constant used for
  "shared / no active env" scoping.

### MCP extension point
- `struct MCPServer`
  - `static func registerTool(schema: [String: Any], handler: @escaping ([String: Any]) -> [String: Any])` — idempotent-on-name; safe before `run()`.
  - `static func execCommand(_ args: [String]) -> [String: Any]` — spawns via `/usr/bin/env`; returns `{ "content": [...], "isError": Bool }`.
  - `static func toolError(_ message: String) -> [String: Any]` — MCP error envelope.

### Localization
- `enum L10n` + `enum L10n.Magi` + `enum L10n.ToolFlag` namespaces.
  Individual keys are **not** part of this contract (they are
  implementation details of user-facing strings); see
  `l10n-signatures.json` for the signature surface instead.

### Other used symbols
- `enum OrreryVersion` — `static var current` (string literal).
- `struct SpecGenerator` — `static func generate(inputPath:outputPath:profile:tool:review:environment:store:) throws -> String` (used by `MagiCommand --spec`).
- `struct LegacyOrbitalMigration` — `static func runIfNeeded()`.

## Indirect / monitored surface

Symbols that `OrreryMagi` does not `import` directly but whose behaviour
it depends on. Changes here require coordinated review:

- `struct DelegateProcessBuilder` — the single subprocess-spawning
  primitive used by `ProcessAgentExecutor`. Treated as stable; any
  change to its semantics (argv, env injection, output-mode contract)
  propagates to Magi.
- Session file formats per tool:
  - claude-code: `<env>/projects/<project-key>/*.jsonl`
  - codex:       `<env>/sessions/YYYY/MM/DD/rollout-*.jsonl`
  - gemini:      `<env>/tmp/<project-hash>/chats/checkpoint-*.json`
  `SessionResolver.findScopedSessions` relies on each layout exactly.
- MCP tool-name namespace: `orrery_*` prefix is treated as Orrery-owned.
  `orrery_magi` is registered by `OrreryMagi`; other `orrery_*` tools
  are registered by `OrreryCore`.

---

## Public surface `OrreryMagi` exposes

Consumed by the `orrery` executable target and (potentially) by
third-party embedders once Phase 2 lands.

### Commands
- `struct MagiCommand: ParsableCommand` — the `orrery magi …` CLI.
  Flag shape is treated as public: `--claude`, `--codex`, `--gemini`,
  `-e/--environment`, `--rounds`, `--output`, `--resume`, `--roles`,
  `--no-summarize`, `--spec`, positional `topic`.

### MCP
- `enum MagiMCPTools`
  - `static func register(on server: MCPServer.Type) throws` — registers
    the `orrery_magi` MCP tool. Idempotent per process. Throws
    `MagiSidecarError` if the sidecar binary is missing or its
    capabilities handshake fails. The schema served to MCP clients is
    the live `--print-mcp-schema` output of the resolved sidecar.

### Sidecar

`MagiSidecar` is the only execution path: there is no in-process
fallback. `MagiCommand.run()` and `MagiMCPTools.register(on:)` both
resolve and dispatch through this surface; failure to resolve is a
hard error.

- `enum MagiSidecarError: Error, CustomStringConvertible`
  - `.binaryNotFound`
  - `.capabilitiesFailed(stderr:)`
  - `.capabilitiesInvalidJSON`
  - `.schemaVersionUnsupported(found:max:)`
  - `.shimProtocolIncompatible(found:required:)`
  - `.mcpSchemaFetchFailed`
- `enum MagiSidecar`
  - `struct ResolvedBinary` — `path`, `version`, `mcpSchema: [String: Any]?`.
  - `struct SpawnResult` — `stdout`, `stderr`, `exitCode`, `timedOut`.
  - `static let maxSchemaVersion: Int` — highest capabilities `$schema_version`
    the shim accepts.
  - `static let shimProtocolVersion: Int` — minimum `compatibility.shim_protocol`
    the shim requires from the sidecar.
  - `static func resolve() throws -> ResolvedBinary` — handshake or
    throw `MagiSidecarError`. The single resolution entry-point.
  - `static func dispatch(_ binary: ResolvedBinary, args: [String]) throws`
    — exec the sidecar inheriting parent stdio; throws `ArgumentParser.ExitCode`
    on non-zero subprocess exit. Propagates parent env + cwd.
  - `static func spawnAndCapture(binary:args:timeout:) -> SpawnResult` —
    capture stdout/stderr with watchdog timeout; safe against grandchild
    fd inheritance deadlocks.

**Binary lookup order** — `ORRERY_MAGI_PATH` env var → `$ORRERY_HOME/bin/orrery-magi`
(default `~/.orrery/bin/orrery-magi`) → `which orrery-magi` on `PATH`.
First match wins.

### Persisted run JSON

Magi run output (written by the sidecar to
`$ORRERY_HOME/<env>/magi/*.json`) is part of the cross-binary contract,
**but its Swift type definition lives in the sibling `orrery-magi`
repo**, not here. This shim does not deserialize it. Callers that
inspect the persisted JSON should treat it as opaque or use
`JSONSerialization` against documented top-level keys (`runId`,
`sessionMap`, `rounds`, `finalVerdict`).

### Module metadata
- `enum OrreryMagiModule`
  - `static var apiVersion: String` — bumped on breaking changes to
    any symbol listed above.

---

## Breaking-change rule

Changes to any symbol in **Direct public surface** (`OrreryCore` side
consumed by `OrreryMagi`) or **Public surface `OrreryMagi` exposes**
require:

1. A CHANGELOG entry calling out the break and the migration path.
2. Updating `OrreryMagi.apiVersion`.
3. When Phase 2 lands, a coordinated tag across both repos.

Additive changes (new public symbols, new optional fields on structs)
do not require an apiVersion bump — only behavioural / removal /
rename changes.

## 2026-07-01 Go / No-Go review

At or before 2026-07-01, evaluate whether the sibling `orrery-magi`
repository should cut its first independent release (Phase 3) and
become a recommended brew formula dependency. Criteria to consider:

- **Stability**: has this contract held for ≥ 2 months without a
  break?
- **Cross-binary version drift**: how often did Orrery and orrery-magi
  need lockstep upgrades to stay compatible?
- **Operational cost**: is the two-binary install (`orrery` + `orrery-magi`)
  acceptable to users, or is `orrery magi` regularly hitting "binary
  not found" errors in support reports?

If ≥ 2 criteria are "yes", cut the orrery-magi v1.0.0 release and
update the orrery brew formula to declare orrery-magi as a recommended
dependency. Otherwise defer and re-evaluate one release later.
