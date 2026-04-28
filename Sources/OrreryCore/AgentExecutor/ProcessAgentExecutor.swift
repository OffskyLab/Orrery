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

    public func execute(request: AgentExecutionRequest) throws -> AgentExecutionResult {
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

        // Start draining stdout/stderr on background threads BEFORE
        // process.run() to avoid pipe backpressure deadlocks.
        var stdoutData = Data()
        var stderrData = Data()
        let stdoutQueue = DispatchQueue(label: "orrery.executor.stdout.\(tool.rawValue)")
        let stderrQueue = DispatchQueue(label: "orrery.executor.stderr.\(tool.rawValue)")
        let stdoutGroup = DispatchGroup()
        let stderrGroup = DispatchGroup()

        stdoutGroup.enter()
        stdoutQueue.async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            stdoutGroup.leave()
        }
        stderrGroup.enter()
        stderrQueue.async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrGroup.leave()
        }

        // Schedule timeout termination. `timeout == 0` disables the
        // watchdog — callers opt into "cancel externally or run forever".
        let timeoutWork: DispatchWorkItem?
        if request.timeout > 0 {
            let work = DispatchWorkItem { [weak process] in
                process?.terminate()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + request.timeout, execute: work)
            timeoutWork = work
        } else {
            timeoutWork = nil
        }

        // Publish the process reference so `cancel()` can find it.
        lock.lock()
        currentProcess = process
        lock.unlock()

        defer {
            lock.lock()
            currentProcess = nil
            lock.unlock()
        }

        // Launch. Re-throw POSIX errors verbatim so callers can inspect
        // errno (EACCES / ENOENT / ETXTBSY / ENOEXEC / EISDIR).
        do {
            try process.run()
        } catch {
            timeoutWork?.cancel()
            // Close the read ends so the draining threads don't block
            // forever on a process that never launched.
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            throw error
        }

        process.waitUntilExit()
        timeoutWork?.cancel()

        // Wait for I/O threads to drain the pipes.
        stdoutGroup.wait()
        stderrGroup.wait()

        let exitCode = process.terminationStatus
        // SIGTERM (15) from uncaughtSignal == our watchdog fired.
        let timedOut = (process.terminationReason == .uncaughtSignal && exitCode == 15)
        let duration = Date().timeIntervalSince(startTime)

        let rawOutput = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrOutput = String(data: stderrData, encoding: .utf8) ?? ""

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
        // Callers that don't want this can suppress stderr at the Process
        // layer — matches prior behavior.
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
        lock.lock()
        let proc = currentProcess
        lock.unlock()
        proc?.terminate()
    }

    private func debugLog(_ message: String) {
        let value = ProcessInfo.processInfo.environment["ORRERY_MAGI_DEBUG"]?.lowercased()
        guard value == "1" || value == "true" else { return }
        FileHandle.standardError.write(Data("[orrery-magi-debug] \(message)\n".utf8))
    }
}
