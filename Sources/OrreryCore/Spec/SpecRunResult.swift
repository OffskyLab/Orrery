import Foundation

/// Structured result of an `orrery spec-run` phase. Serialised to stdout as
/// JSON and returned to MCP clients verbatim. Shape is stable across error
/// and success paths — validation errors populate the `error` field and leave
/// other collections empty, so clients can always decode the same struct.
///
/// Swift API uses camelCase; JSON surfaces snake_case through explicit
/// `CodingKeys`. See spec §2 (verify) and §2/§3 (implement MVP).
public struct SpecRunResult: Encodable {
    // Original verify-phase fields
    public let sessionId: String?
    public let phase: String
    public let completedSteps: [String]
    public let verification: VerificationResult
    public let summaryMarkdown: String
    public let stderr: String
    public let diffSummary: String?
    public let review: ReviewOutcome?
    public let error: String?

    // Implement-phase fields (also populated — with safe defaults — for verify)
    public let status: String           // pass | fail | done | running | failed | aborted | skipped_dry_run
    public let startedAt: String        // ISO8601; may be "" for legacy verify results
    public let completedAt: String?
    public let touchedFiles: [String]
    public let blockedReason: String?
    public let failedStep: String?
    public let childSessionIds: [String]   // DI3 reserve — MVP always []
    public let executionGraph: String?     // DI3 reserve — MVP always nil

    public init(
        sessionId: String?,
        phase: String,
        completedSteps: [String],
        verification: VerificationResult,
        summaryMarkdown: String,
        stderr: String,
        diffSummary: String?,
        review: ReviewOutcome?,
        error: String?,
        status: String = "done",
        startedAt: String = "",
        completedAt: String? = nil,
        touchedFiles: [String] = [],
        blockedReason: String? = nil,
        failedStep: String? = nil,
        childSessionIds: [String] = [],
        executionGraph: String? = nil
    ) {
        self.sessionId = sessionId
        self.phase = phase
        self.completedSteps = completedSteps
        self.verification = verification
        self.summaryMarkdown = summaryMarkdown
        self.stderr = stderr
        self.diffSummary = diffSummary
        self.review = review
        self.error = error
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.touchedFiles = touchedFiles
        self.blockedReason = blockedReason
        self.failedStep = failedStep
        self.childSessionIds = childSessionIds
        self.executionGraph = executionGraph
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case phase
        case completedSteps = "completed_steps"
        case verification
        case summaryMarkdown = "summary_markdown"
        case stderr
        case diffSummary = "diff_summary"
        case review
        case error
        case status
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case touchedFiles = "touched_files"
        case blockedReason = "blocked_reason"
        case failedStep = "failed_step"
        case childSessionIds = "child_session_ids"
        case executionGraph = "execution_graph"
    }

    /// Explicit encode so nil Optionals surface as JSON `null` (schema stability, H5/DI6).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(phase, forKey: .phase)
        try c.encode(completedSteps, forKey: .completedSteps)
        try c.encode(verification, forKey: .verification)
        try c.encode(summaryMarkdown, forKey: .summaryMarkdown)
        try c.encode(stderr, forKey: .stderr)
        try c.encode(diffSummary, forKey: .diffSummary)
        try c.encode(review, forKey: .review)
        try c.encode(error, forKey: .error)
        try c.encode(status, forKey: .status)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(completedAt, forKey: .completedAt)
        try c.encode(touchedFiles, forKey: .touchedFiles)
        try c.encode(blockedReason, forKey: .blockedReason)
        try c.encode(failedStep, forKey: .failedStep)
        try c.encode(childSessionIds, forKey: .childSessionIds)
        try c.encode(executionGraph, forKey: .executionGraph)
    }

    /// Build a schema-stable error payload for validation failures.
    public static func errorShell(phase: String, error: String) -> SpecRunResult {
        let nowIso = ISO8601DateFormatter().string(from: Date())
        return SpecRunResult(
            sessionId: nil,
            phase: phase,
            completedSteps: [],
            verification: VerificationResult(checklist: [], testResults: []),
            summaryMarkdown: "",
            stderr: "",
            diffSummary: nil,
            review: nil,
            error: error,
            status: "failed",
            startedAt: nowIso,
            completedAt: nowIso
        )
    }

    /// Construct an implement-phase `SpecRunResult` from a persisted
    /// `SpecRunState`. Used by:
    /// - early-return path (Runner `watch == false`): state reflects "running"
    /// - watch path after delegate exits: state reflects terminal status
    /// - SpecStatusResult.result when status != "running"
    ///
    /// Note: does NOT expose `delegateSessionId` / `preSessionSnapshot` — those
    /// are orrery-internal bookkeeping (see spec §7 C2 exclusion rule).
    public static func fromImplementState(_ state: SpecRunState) -> SpecRunResult {
        SpecRunResult(
            sessionId: state.sessionId,
            phase: state.phase,
            completedSteps: state.completedSteps,
            verification: VerificationResult(checklist: [], testResults: []),
            summaryMarkdown: "",
            stderr: "",
            diffSummary: state.diffSummary,
            review: nil,
            error: state.lastError,
            status: state.status,
            startedAt: state.startedAt,
            completedAt: state.completedAt,
            touchedFiles: state.touchedFiles,
            blockedReason: state.blockedReason,
            failedStep: state.failedStep,
            childSessionIds: state.childSessionIds,
            executionGraph: state.executionGraph
        )
    }

    public func toJSONString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - VerificationResult

public struct VerificationResult: Encodable {
    public let checklist: [ChecklistOutcome]
    public let testResults: [CommandOutcome]

    public init(checklist: [ChecklistOutcome], testResults: [CommandOutcome]) {
        self.checklist = checklist
        self.testResults = testResults
    }

    enum CodingKeys: String, CodingKey {
        case checklist
        case testResults = "test_results"
    }
}

// MARK: - OutcomeStatus

/// Shared status label for checklist items and command results.
/// JSON wire format: `pass | fail | skipped | policy_blocked`.
public enum OutcomeStatus: String, Encodable {
    case pass
    case fail
    case skipped
    case policyBlocked = "policy_blocked"
}

// MARK: - ChecklistOutcome

public struct ChecklistOutcome: Encodable {
    public let item: String
    public let status: OutcomeStatus
    public let evidence: String

    public init(item: String, status: OutcomeStatus, evidence: String) {
        self.item = item
        self.status = status
        self.evidence = evidence
    }
}

// MARK: - CommandOutcome

public struct CommandOutcome: Encodable {
    public let command: String
    public let status: OutcomeStatus
    public let exitCode: Int32
    public let stdoutSnippet: String
    public let stderrSnippet: String
    public let durationMs: Int
    public let skippedReason: String?

    public init(
        command: String,
        status: OutcomeStatus,
        exitCode: Int32,
        stdoutSnippet: String,
        stderrSnippet: String,
        durationMs: Int,
        skippedReason: String?
    ) {
        self.command = command
        self.status = status
        self.exitCode = exitCode
        self.stdoutSnippet = stdoutSnippet
        self.stderrSnippet = stderrSnippet
        self.durationMs = durationMs
        self.skippedReason = skippedReason
    }

    enum CodingKeys: String, CodingKey {
        case command
        case status
        case exitCode = "exit_code"
        case stdoutSnippet = "stdout_snippet"
        case stderrSnippet = "stderr_snippet"
        case durationMs = "duration_ms"
        case skippedReason = "skipped_reason"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(command, forKey: .command)
        try c.encode(status, forKey: .status)
        try c.encode(exitCode, forKey: .exitCode)
        try c.encode(stdoutSnippet, forKey: .stdoutSnippet)
        try c.encode(stderrSnippet, forKey: .stderrSnippet)
        try c.encode(durationMs, forKey: .durationMs)
        try c.encode(skippedReason, forKey: .skippedReason)
    }
}

// MARK: - ReviewOutcome

public struct ReviewOutcome: Encodable {
    /// JSON wire format: `pass | fail | advisory_only`.
    public enum Verdict: String, Encodable {
        case pass
        case fail
        case advisoryOnly = "advisory_only"
    }

    public let verdict: Verdict
    public let reasoning: String
    public let flaggedItems: [String]

    public init(verdict: Verdict, reasoning: String, flaggedItems: [String]) {
        self.verdict = verdict
        self.reasoning = reasoning
        self.flaggedItems = flaggedItems
    }

    enum CodingKeys: String, CodingKey {
        case verdict
        case reasoning
        case flaggedItems = "flagged_items"
    }
}

// MARK: - SpecStatusResult (orrery_spec_status output shape)

/// Returned by `orrery spec-run --mode status --session-id <id>` and the
/// `orrery_spec_status` MCP tool. See spec §3.
public struct SpecStatusResult: Encodable {
    public let sessionId: String
    public let phase: String
    public let status: String                 // running | done | failed | aborted
    public let startedAt: String
    public let updatedAt: String
    public let progress: ProgressSnapshot
    public let lastError: String?
    public let result: SpecRunResult?         // populated only when status != "running"
    public let logTail: [String]

    public struct ProgressSnapshot: Encodable {
        public let currentStep: String?
        public let totalSteps: Int?

        public init(currentStep: String?, totalSteps: Int?) {
            self.currentStep = currentStep
            self.totalSteps = totalSteps
        }

        enum CodingKeys: String, CodingKey {
            case currentStep = "current_step"
            case totalSteps = "total_steps"
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(currentStep, forKey: .currentStep)
            try c.encode(totalSteps, forKey: .totalSteps)
        }
    }

    public init(
        sessionId: String,
        phase: String,
        status: String,
        startedAt: String,
        updatedAt: String,
        progress: ProgressSnapshot,
        lastError: String?,
        result: SpecRunResult?,
        logTail: [String]
    ) {
        self.sessionId = sessionId
        self.phase = phase
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.progress = progress
        self.lastError = lastError
        self.result = result
        self.logTail = logTail
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case phase
        case status
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case progress
        case lastError = "last_error"
        case result
        case logTail = "log_tail"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(phase, forKey: .phase)
        try c.encode(status, forKey: .status)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(progress, forKey: .progress)
        try c.encode(lastError, forKey: .lastError)
        try c.encode(result, forKey: .result)
        try c.encode(logTail, forKey: .logTail)
    }

    /// Construct a status result from persisted state plus optionally-populated
    /// log tail. `result` is filled with `SpecRunResult.fromImplementState` iff
    /// the session has reached a terminal status.
    public static func from(state: SpecRunState, logTail: [String]) -> SpecStatusResult {
        let isTerminal = state.status != "running"
        let result: SpecRunResult? = isTerminal ? .fromImplementState(state) : nil

        // Derive progress snapshot from in-memory state. MVP approximation:
        // - current_step = failedStep if populated, else last element of completedSteps (best-effort)
        // - total_steps = nil (spec's unknown until plan phase provides it)
        let currentStep: String?
        if let fs = state.failedStep {
            currentStep = fs
        } else if state.status == "running", let last = state.completedSteps.last {
            currentStep = "after:\(last)"
        } else {
            currentStep = state.completedSteps.last
        }
        let progress = ProgressSnapshot(currentStep: currentStep, totalSteps: nil)

        return SpecStatusResult(
            sessionId: state.sessionId,
            phase: state.phase,
            status: state.status,
            startedAt: state.startedAt,
            updatedAt: state.updatedAt,
            progress: progress,
            lastError: state.lastError,
            result: result,
            logTail: logTail
        )
    }

    public func toJSONString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
