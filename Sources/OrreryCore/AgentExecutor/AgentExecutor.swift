import Foundation

/// Abstraction over "spawn an AI-tool subprocess, hand it a prompt, and
/// collect its output + session id + timing". Introduced by Magi
/// extraction (DI12 middle-ground):
///
/// - `execute(request:)` — synchronous one-shot; throws on launch error.
/// - `cancel()` — idempotent; kills the in-flight subprocess if any.
/// - `sessionId` stays as a first-class field on the result (Magi
///   persists + resumes it across rounds; demoting to `metadata` would
///   force every caller to know a magic key).
/// - `Tool` enum stays as the tool identifier (MVP pragmatism — the
///   alternative of `agentIdentifier: String` was debated and deferred;
///   see extraction discussion Q3 / Gemini R2 策略性補充).
/// - Streaming / event callbacks intentionally deferred. The
///   `metadata: [String: String]` field on `AgentExecutionResult` is the
///   forward-compatible carrier for future additions (token counts,
///   model version, etc.) without breaking the protocol shape.
///
/// Callers in `OrreryCore` stay API-free (they just use the protocol);
/// the concrete implementation `ProcessAgentExecutor` wraps the existing
/// `DelegateProcessBuilder` + `SessionResolver` machinery, which remains
/// an internal implementation detail.
public protocol AgentExecutor {
    /// Run the delegate synchronously, respecting the request's timeout
    /// via an internal watchdog. Throws only for launch-level errors
    /// (POSIX EACCES / ENOENT / ETXTBSY etc.); subprocess-level failures
    /// are surfaced via `AgentExecutionResult.exitCode` and
    /// `AgentExecutionResult.timedOut`.
    func execute(request: AgentExecutionRequest) throws -> AgentExecutionResult

    /// Best-effort cancellation. Safe to call before `execute` returns
    /// (sends SIGTERM to the inflight subprocess) or after (no-op).
    /// Intentionally fire-and-forget: caller does not await termination.
    func cancel()
}

// MARK: - Request

public struct AgentExecutionRequest: Equatable {
    public let tool: Tool
    public let prompt: String
    public let resumeSessionId: String?
    /// Overall seconds before the executor internally terminates the
    /// subprocess. `0` disables the watchdog (caller is responsible for
    /// external cancellation).
    public let timeout: TimeInterval
    /// Forward-compat payload. MVP callers can leave this empty. Reserved
    /// keys (suggested):
    /// - `token_budget` — advisory hint forwarded to the delegate.
    /// - `environment` — orrery environment name (only if a caller
    ///   prefers request-carried env over the executor's bound env).
    /// Unknown keys are silently ignored.
    public let metadata: [String: String]

    public init(
        tool: Tool,
        prompt: String,
        resumeSessionId: String? = nil,
        timeout: TimeInterval,
        metadata: [String: String] = [:]
    ) {
        self.tool = tool
        self.prompt = prompt
        self.resumeSessionId = resumeSessionId
        self.timeout = timeout
        self.metadata = metadata
    }
}

// MARK: - Result

public struct AgentExecutionResult: Equatable {
    public let tool: Tool
    public let rawOutput: String
    public let stderrOutput: String
    public let exitCode: Int32
    public let timedOut: Bool
    /// Delegate's native session id (captured via `SessionResolver`
    /// snapshot-diff after the subprocess exits). `nil` when the
    /// delegate did not create a new session (launch failure, ambiguous
    /// diff, or the delegate reused an existing session).
    public let sessionId: String?
    public let duration: TimeInterval
    /// Forward-compat payload. MVP executors emit an empty dictionary.
    public let metadata: [String: String]

    public init(
        tool: Tool,
        rawOutput: String,
        stderrOutput: String,
        exitCode: Int32,
        timedOut: Bool,
        sessionId: String?,
        duration: TimeInterval,
        metadata: [String: String] = [:]
    ) {
        self.tool = tool
        self.rawOutput = rawOutput
        self.stderrOutput = stderrOutput
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.sessionId = sessionId
        self.duration = duration
        self.metadata = metadata
    }
}
