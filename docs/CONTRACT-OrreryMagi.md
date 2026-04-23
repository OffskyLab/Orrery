# `OrreryMagi` — Public Surface Contract

**Status**: Phase 1 (repo-internal modularization) — 2026-04-22
**Go/No-Go review for Phase 2 (split to separate repo)**: **2026-07-01**

This document is the authoritative contract between `OrreryMagi` and its
consumers. It exists because the Magi extraction is a two-phase
refactor: Phase 1 carved `OrreryMagi` out of `OrreryCore` inside the same
repo; Phase 2 may promote it to an independent package. Anything listed
here must stay stable through Phase 1 so Phase 2 is a non-event for
external consumers.

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
  - `static func register(on server: MCPServer.Type)` — registers the
    `orrery_magi` MCP tool. Idempotent per process.

### Orchestration model
- `struct MagiRun` (+ nested: `MagiRound`, `MagiAgentResponse`,
  `MagiPositionEntry`, `MagiVote`, `ConsensusItem`, `FinalVerdict`,
  `VerdictDecision`). These are the on-disk JSON shapes of persisted
  runs — the **persisted schema is part of this contract**; old files
  must keep loading across refactors.
- `enum MagiPosition` (`agree` / `disagree` / `conditional`).
- `enum ConsensusStatus` (`agreed` / `majority` / `disputed` / `pending`).
- `enum MagiRunStatus` (`inProgress` / `maxRoundsReached` / `converged`).
- `struct MagiRole`, `enum MagiRolePreset` (`balanced` / `adversarial` / `security`).

### Entry points
- `enum MagiOrchestrator`
  - `static func run(topic:subtopics:tools:maxRounds:environment:store:outputPath:previousRunId:noSummarize:roles:) throws -> MagiRun`
  - `static func generateReport(run: MagiRun) -> String`
- `struct MagiPromptBuilder` — `static func buildPrompt(...)` (stable
  only for internal orchestration use; not a primary API).
- `struct MagiResponseParser` — `static func parse(rawOutput:subtopics:)`.

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

At or before 2026-07-01, evaluate whether `OrreryMagi` should be
promoted to a separate repo (Phase 2). Criteria to consider:

- Stability: has this contract held for ≥ 2 months without a break?
- External demand: has anyone (other than `orrery`) tried to depend on
  Magi directly?
- Friction cost: are cross-target changes now disproportionately
  expensive to ship in a single PR?

If ≥ 2 criteria are "yes", proceed to Phase 2 split. Otherwise defer
and re-evaluate one release later.
