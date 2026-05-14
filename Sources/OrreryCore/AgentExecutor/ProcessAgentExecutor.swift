import Foundation

/// Concrete `AgentExecutor` that spawns the delegate CLI via
/// `DelegateProcessBuilder` and captures stdout/stderr/session-id.
///
/// This is a straight port of the I/O drain + timeout watchdog +
/// session-id diff logic previously embedded in `MagiAgentRunner`; the
/// behavior is intentionally preserved so the Magi extraction stays a
/// "move only, don't change" change (see extraction M3).
///
/// Environment binding (`cwd` / `store` / `activeEnvironment`) is fixed
/// at construction time — one executor instance targets one environment.
/// The executor is reusable: `execute` builds a fresh `Process` per
/// invocation, so the same executor can run many requests serially.
///
/// `cancel()` is idempotent and safe to call before `execute` returns
/// (signals SIGTERM to the inflight subprocess) or after (no-op).
public final class ProcessAgentExecutor: AgentExecutor {
    private let cwd: String
    private let store: EnvironmentStore
    private let activeEnvironment: String?

    // Guards `currentProcess`. `cancel()` may be invoked from any thread;
    // keep the critical sections narrow (set / read reference only).
    private let lock = NSLock()
    private var currentProcess: Process?

    public init(
        cwd: String = FileManager.default.currentDirectoryPath,
        store: EnvironmentStore,
        activeEnvironment: String?
    ) {
        self.cwd = cwd
        self.store = store
        self.activeEnvironment = activeEnvironment
    }

    public func execute(request: AgentExecutionRequest) async throws -> AgentExecutionResult {
        let tool = request.tool
        let env = ProcessInfo.processInfo.environment

        // Snapshot session IDs before launch — diff after exit yields
        // the delegate's native session id.
        let preSnapshot = Set(
            SessionResolver.findScopedSessions(
                tool: tool, cwd: cwd, store: store,
                activeEnvironment: activeEnvironment
            ).map(\.id)
        )
        debugLog(
            "tool=\(tool.rawValue) cwd=\(cwd) ORRERY_HOME=\(env["ORRERY_HOME"] ?? "") "
                + "ORRERY_ACTIVE_ENV=\(env["ORRERY_ACTIVE_ENV"] ?? "") "
                + "pre_snapshot_count=\(preSnapshot.count)"
        )

        let startTime = Date()

        // Build the process. DelegateProcessBuilder throws only on
        // configuration errors (missing tool, bad env); those propagate
        // as the protocol's "launch-level" errors.
        let builder = DelegateProcessBuilder(
            tool: tool, prompt: request.prompt,
            resumeSessionId: request.resumeSessionId,
            environment: activeEnvironment, store: store
        )
        let (process, _, outputPipe) = try builder.build(outputMode: .capture)
        let stdoutPipe = outputPipe ?? Pipe()
        let stderrPipe = Pipe()

        // Runner owns stderr — override what DelegateProcessBuilder set.
        process.standardError = stderrPipe
        if outputPipe == nil {
            process.standardOutput = stdoutPipe
        }

        // Start draining stdout/stderr with detached tasks BEFORE process.run()
        // to avoid pipe backpressure deadlocks. Task.detached prevents
        // actor-isolation issues and lets reads run truly concurrently.
        let stdoutReadTask = Task.detached {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrReadTask = Task.detached {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        // Schedule timeout via a cancellable Task. `timeout == 0` disables it.
        let timeoutTask: Task<Void, Never>?
        if request.timeout > 0 {
            let timeout = request.timeout
            timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    process.terminate()
                } catch { /* cancelled before firing */ }
            }
        } else {
            timeoutTask = nil
        }

        // Publish the process reference so `cancel()` can find it.
        lock.withLock { currentProcess = process }

        defer {
            lock.withLock { currentProcess = nil }
            timeoutTask?.cancel()
        }

        // Launch. Re-throw POSIX errors verbatim so callers can inspect
        // errno (EACCES / ENOENT / ETXTBSY / ENOEXEC / EISDIR).
        do {
            try process.run()
        } catch {
            timeoutTask?.cancel()
            // Close the read ends so the drain tasks don't block forever.
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            _ = await (stdoutReadTask.value, stderrReadTask.value)
            throw error
        }

        process.waitUntilExit()
        timeoutTask?.cancel()

        let exitCode = process.terminationStatus
        // SIGTERM (15) from uncaughtSignal == our watchdog fired.
        let timedOut = (process.terminationReason == .uncaughtSignal && exitCode == 15)
        let duration = Date().timeIntervalSince(startTime)

        let rawOutput = String(data: await stdoutReadTask.value, encoding: .utf8) ?? ""
        let stderrOutput = String(data: await stderrReadTask.value, encoding: .utf8) ?? ""

        // Post-snapshot diff — exactly one new session id => that's ours.
        let postSnapshot = Set(
            SessionResolver.findScopedSessions(
                tool: tool, cwd: cwd, store: store,
                activeEnvironment: activeEnvironment
            ).map(\.id)
        )
        let diff = postSnapshot.subtracting(preSnapshot)
        debugLog(
            "tool=\(tool.rawValue) cwd=\(cwd) ORRERY_HOME=\(env["ORRERY_HOME"] ?? "") "
                + "ORRERY_ACTIVE_ENV=\(env["ORRERY_ACTIVE_ENV"] ?? "") "
                + "post_snapshot_count=\(postSnapshot.count) diff_count=\(diff.count)"
        )
        let sessionId = diff.count == 1 ? diff.first : nil

        // Preserve the Magi "session id not found" warning on stderr
        // when we expected one (clean exit, not timed out, but no diff).
        if sessionId == nil && !timedOut && exitCode == 0 {
            FileHandle.standardError.write(
                Data((L10n.Magi.sessionIdNotFound(tool.rawValue) + "\n").utf8))
        }

        return AgentExecutionResult(
            tool: tool,
            rawOutput: rawOutput,
            stderrOutput: stderrOutput,
            exitCode: exitCode,
            timedOut: timedOut,
            sessionId: sessionId,
            duration: duration,
            metadata: [:]
        )
    }

    public func cancel() {
        lock.withLock { currentProcess }?.terminate()
    }

    private func debugLog(_ message: String) {
        let value = ProcessInfo.processInfo.environment["ORRERY_MAGI_DEBUG"]?.lowercased()
        guard value == "1" || value == "true" else { return }
        FileHandle.standardError.write(Data("[orrery-magi-debug] \(message)\n".utf8))
    }
}
