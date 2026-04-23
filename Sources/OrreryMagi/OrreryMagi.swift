import Foundation
import OrreryCore

/// `OrreryMagi` — extracted Magi consensus library.
///
/// Phase 1 (repo-internal modularization) of the Magi extraction plan:
/// the multi-agent consensus logic (MagiOrchestrator / MagiRun /
/// MagiPromptBuilder / MagiAgentRunner → ProcessAgentExecutor) moves
/// into its own library target, depending on `OrreryCore` for shared
/// primitives (Tool, EnvironmentStore, SessionResolver, L10n,
/// AgentExecutor protocol).
///
/// Target is created in M4 as an empty scaffold; actual source moves
/// happen in M5. See `docs/tasks/2026-04-17-magi-extraction.md`.
public enum OrreryMagiModule {
    /// Semantic version of the library API surface. Bumped when the
    /// public DTOs / orchestrator entry points change in a way that
    /// would break external consumers (Phase 2 prep).
    public static let apiVersion = "0.1.0"
}
