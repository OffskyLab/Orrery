import Foundation
import OrreryCore

/// `OrreryMagi` — sidecar shim library.
///
/// After Phase 2 Step 4, this target is a thin wrapper around the
/// external `orrery-magi` binary. It exposes:
///   - `MagiCommand` (the `orrery magi …` subcommand shell).
///   - `MagiMCPTools.register(on:)` (the `orrery_magi` MCP tool, with
///     the schema served from the sidecar's live capabilities).
///   - `MagiSidecar` (binary lookup + capabilities handshake +
///     dispatch primitives).
///
/// All Magi orchestration (MagiOrchestrator / MagiRun /
/// MagiPromptBuilder / MagiResponseParser / DTOs) ships in the sibling
/// `orrery-magi` repository. See `docs/CONTRACT-OrreryMagi.md`.
public enum OrreryMagiModule {
    /// Semantic version of the library API surface. Bumped on any
    /// breaking change to `MagiCommand`, `MagiMCPTools`, or
    /// `MagiSidecar`. 1.0.0 marks the Phase 2 Step 4 cut: removal of
    /// in-process orchestration and collapse of the strict-mode API
    /// to a single `resolve()` entry-point.
    public static let apiVersion = "1.0.0"
}
