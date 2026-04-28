import ArgumentParser
import Foundation

/// Persistent state for one `orrery spec-run --mode implement` session.
/// Lives at `~/.orrery/spec-runs/{session_id}.json` (or under
/// `$ORRERY_HOME/spec-runs/` when `ORRERY_HOME` is set — same override
/// pattern as `EnvironmentStore.default`). See spec §7.
///
/// Internal fields `delegateSessionId` and `preSessionSnapshot` are
/// bookkeeping for the C1/C2 architecture; they are **not** exposed in
/// `orrery_spec_implement` / `orrery_spec_status` output schemas.
public struct SpecRunState: Codable, Equatable {
    public var sessionId: String
    public var delegateSessionId: String?      // C2: delegate CLI's native session id
    public var preSessionSnapshot: [String]    // C1: scoped session ids captured before delegate spawn
    public var phase: String                   // always "implement" for now
    public var status: String                  // running | done | failed | aborted
    public var startedAt: String
    public var updatedAt: String
    public var completedAt: String?
    public var completedSteps: [String]
    public var touchedFiles: [String]
    public var diffSummary: String?
    public var blockedReason: String?
    public var failedStep: String?
    public var childSessionIds: [String]       // DI3 reserved — MVP always []
    public var executionGraph: String?         // DI3 reserved — MVP always nil
    public var lastError: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case delegateSessionId = "delegate_session_id"
        case preSessionSnapshot = "pre_session_snapshot"
        case phase
        case status
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
        case completedSteps = "completed_steps"
        case touchedFiles = "touched_files"
        case diffSummary = "diff_summary"
        case blockedReason = "blocked_reason"
        case failedStep = "failed_step"
        case childSessionIds = "child_session_ids"
        case executionGraph = "execution_graph"
        case lastError = "last_error"
    }

    public init(
        sessionId: String,
        delegateSessionId: String? = nil,
        preSessionSnapshot: [String] = [],
        phase: String = "implement",
        status: String = "running",
        startedAt: String,
        updatedAt: String,
        completedAt: String? = nil,
        completedSteps: [String] = [],
        touchedFiles: [String] = [],
        diffSummary: String? = nil,
        blockedReason: String? = nil,
        failedStep: String? = nil,
        childSessionIds: [String] = [],
        executionGraph: String? = nil,
        lastError: String? = nil
    ) {
        self.sessionId = sessionId
        self.delegateSessionId = delegateSessionId
        self.preSessionSnapshot = preSessionSnapshot
        self.phase = phase
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.completedSteps = completedSteps
        self.touchedFiles = touchedFiles
        self.diffSummary = diffSummary
        self.blockedReason = blockedReason
        self.failedStep = failedStep
        self.childSessionIds = childSessionIds
        self.executionGraph = executionGraph
        self.lastError = lastError
    }

    /// Explicit `encode(to:)` so nil Optionals appear as JSON `null` instead
    /// of being omitted (schema stability — aligns with SpecRunResult pattern).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(delegateSessionId, forKey: .delegateSessionId)
        try c.encode(preSessionSnapshot, forKey: .preSessionSnapshot)
        try c.encode(phase, forKey: .phase)
        try c.encode(status, forKey: .status)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(completedAt, forKey: .completedAt)
        try c.encode(completedSteps, forKey: .completedSteps)
        try c.encode(touchedFiles, forKey: .touchedFiles)
        try c.encode(diffSummary, forKey: .diffSummary)
        try c.encode(blockedReason, forKey: .blockedReason)
        try c.encode(failedStep, forKey: .failedStep)
        try c.encode(childSessionIds, forKey: .childSessionIds)
        try c.encode(executionGraph, forKey: .executionGraph)
        try c.encode(lastError, forKey: .lastError)
    }

    /// Convenience factory for a fresh `"running"` state.
    public static func initial(sessionId: String, startedAt: String) -> SpecRunState {
        SpecRunState(
            sessionId: sessionId,
            startedAt: startedAt,
            updatedAt: startedAt
        )
    }
}

/// Reads and writes `SpecRunState` JSON files in the spec-runs directory.
public struct SpecRunStateStore {

    /// `{ORRERY_HOME | ~/.orrery}/spec-runs/`. Honours the same env override
    /// as `EnvironmentStore.default` so tests (and parallel envs) can pin
    /// a scratch path via `ORRERY_HOME`.
    public static var rootDir: URL {
        EnvironmentStore.default.homeURL
            .appendingPathComponent("spec-runs", isDirectory: true)
    }

    public static func statePath(sessionId: String) -> URL {
        rootDir.appendingPathComponent("\(sessionId).json", isDirectory: false)
    }

    public static func progressLogPath(sessionId: String) -> URL {
        rootDir.appendingPathComponent("\(sessionId).progress.jsonl", isDirectory: false)
    }

    public static func stdoutLogPath(sessionId: String) -> URL {
        rootDir.appendingPathComponent("\(sessionId).stdout.log", isDirectory: false)
    }

    public static func stderrLogPath(sessionId: String) -> URL {
        rootDir.appendingPathComponent("\(sessionId).stderr.log", isDirectory: false)
    }

    // MARK: - CRUD

    /// Write the given state to disk, creating `rootDir` if needed.
    /// Always rewrites the full JSON file (not an append journal).
    public static func write(sessionId: String, state: SpecRunState) throws {
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(state)
        try data.write(to: statePath(sessionId: sessionId))
    }

    /// Load state for `sessionId`. Throws `sessionNotFound` if the file is missing.
    public static func load(sessionId: String) throws -> SpecRunState {
        let url = statePath(sessionId: sessionId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError(L10n.SpecRun.sessionNotFound(sessionId))
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SpecRunState.self, from: data)
    }

    /// Load → mutate → stamp `updatedAt` → write. Atomic enough for single-
    /// writer scenarios (`_spec-finalize` and `SpecImplementRunner` don't
    /// race against each other because finalize only runs after delegate exit).
    public static func update(
        sessionId: String,
        mutate: (inout SpecRunState) -> Void
    ) throws {
        var state = try load(sessionId: sessionId)
        mutate(&state)
        state.updatedAt = ISO8601DateFormatter().string(from: Date())
        try write(sessionId: sessionId, state: state)
    }

    /// Idempotent existence check — returns true if the state file is readable.
    public static func exists(sessionId: String) -> Bool {
        FileManager.default.fileExists(atPath: statePath(sessionId: sessionId).path)
    }
}
