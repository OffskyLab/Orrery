import ArgumentParser
import Foundation

/// Orchestrates the `implement` phase of `orrery spec-run`.
///
/// Core design:
/// - **C1 detached lifecycle via wrapper shell**: Runner spawns a `/bin/bash -c '<wrapper>'`
///   subprocess. Wrapper owns the delegate CLI, handles timeout via watchdog,
///   and invokes `orrery _spec-finalize` after the delegate exits — so
///   finalization works even after this orrery process has exited.
/// - **C2 session id separation**: `sessionId` is our UUID tracking token;
///   `delegateSessionId` is the underlying CLI's native id (captured by
///   `_spec-finalize` via SessionResolver diff). MCP clients only see
///   orrery UUIDs.
/// - **C3 detached stdout routing**: wrapper redirects delegate stdout/stderr
///   to `~/.orrery/spec-runs/{id}.stdout.log` / `.stderr.log`; never touches
///   the orrery parent's stdio (would deadlock once parent exits).
/// - **G1 timeout watchdog**: wrapper spawns a `( sleep N && kill -TERM $PID ) &`
///   background watchdog when `overallTimeout > 0`, honouring the MCP
///   `timeout` input even in detached mode.
/// - **DI2 transport-launch retry**: a single retry for EACCES/ENOENT/ETXTBSY
///   launch failures *before* any log bytes are written; semantic failures
///   are never retried (stop-and-report).
///
/// See spec §4 + Steps 5/6/7 + R2 review fixes G1/G2/G3/G5/G8.
public struct SpecImplementRunner {

    public static func run(
        specPath: String,
        tool: Tool?,
        environment: String?,
        store: EnvironmentStore,
        resumeSessionId: String?,
        overallTimeout: TimeInterval,
        tokenBudget: Int?,
        watch: Bool
    ) throws -> SpecRunResult {

        // MARK: 1. Resolve spec path
        let resolvedPath = resolveSpecPath(specPath)
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            throw ValidationError(L10n.SpecRun.specNotFound(resolvedPath))
        }

        // MARK: 2. Static structure check (DI5 safety net)
        let markdown = try String(contentsOfFile: resolvedPath, encoding: .utf8)
        try SpecAcceptanceParser.validateStructure(markdown: markdown)

        // MARK: 3. Resolve delegate tool
        let resolvedTool = try tool ?? firstAvailableTool()

        // MARK: 4. Session id resolution (C2 + G8)
        let sessionId: String
        let delegateResumeId: String?
        let priorStartedAt: String?
        if let orreryResumeId = resumeSessionId {
            let prior = try SpecRunStateStore.load(sessionId: orreryResumeId)
            sessionId = orreryResumeId
            delegateResumeId = prior.delegateSessionId
            priorStartedAt = prior.startedAt
            if delegateResumeId == nil {
                // G8: silent-fresh fallback is confusing; warn caller explicitly.
                stderrWarn(
                    "resume_session_id=\(orreryResumeId) provided but "
                    + "delegate_session_id was never captured (likely prior run failed "
                    + "before delegate spawned); starting fresh delegate session."
                )
            }
        } else {
            sessionId = UUID().uuidString
            delegateResumeId = nil
            priorStartedAt = nil
        }

        // MARK: 5. Per-session paths
        let progressLogPath = SpecRunStateStore.progressLogPath(sessionId: sessionId).path
        let stdoutLog = SpecRunStateStore.stdoutLogPath(sessionId: sessionId).path
        let stderrLog = SpecRunStateStore.stderrLogPath(sessionId: sessionId).path

        // Ensure root dir exists so wrapper's `>>` append works without
        // "No such file or directory".
        try FileManager.default.createDirectory(
            at: SpecRunStateStore.rootDir,
            withIntermediateDirectories: true
        )

        // MARK: 6. Build prompt (DI4 妥協版: inline interface + acceptance)
        let prompt = try SpecPromptExtractor.buildImplementPrompt(
            markdown: markdown,
            specPath: resolvedPath,
            sessionId: sessionId,
            progressLogPath: progressLogPath,
            tokenBudget: tokenBudget
        )

        // MARK: 7. Pre-snapshot + write initial state
        let preSnapshot = SessionResolver.findScopedSessions(
            tool: resolvedTool,
            cwd: FileManager.default.currentDirectoryPath,
            store: store,
            activeEnvironment: environment
        ).map(\.id)

        let nowIso = ISO8601DateFormatter().string(from: Date())
        let startedAt = priorStartedAt ?? nowIso
        var state = SpecRunState.initial(sessionId: sessionId, startedAt: startedAt)
        state.updatedAt = nowIso
        state.preSessionSnapshot = preSnapshot
        state.delegateSessionId = delegateResumeId   // preserves resume chain
        try SpecRunStateStore.write(sessionId: sessionId, state: state)

        // MARK: 8. Extract delegate command via DelegateProcessBuilder
        // We DON'T run this process; we only use it to derive the correct
        // `claude`/`codex`/`gemini` argv (with env/resume wiring baked in).
        let builder = DelegateProcessBuilder(
            tool: resolvedTool,
            prompt: prompt,
            resumeSessionId: delegateResumeId,
            environment: environment,
            store: store
        )
        let (scratchProcess, _, _) = try builder.build(outputMode: .passthrough)
        let delegateArgs = scratchProcess.arguments ?? []
        let inheritedEnv = scratchProcess.environment ?? [:]

        // MARK: 9. Wrapper shell (C1 + G1 + G3)
        let wrapper = buildWrapperShell(
            delegateArgs: delegateArgs,
            stdoutLog: stdoutLog,
            stderrLog: stderrLog,
            sessionId: sessionId,
            overallTimeout: overallTimeout
        )

        // MARK: 10. Spawn wrapper (with DI2 retry)
        var mergedEnv = inheritedEnv
        mergedEnv["ORRERY_SPEC_PROGRESS_LOG"] = progressLogPath
        mergedEnv["ORRERY_SPEC_SESSION_ID"] = sessionId
        mergedEnv["ORRERY_SPEC_PATH"] = resolvedPath
        mergedEnv["ORRERY_SPEC_TOOL"] = resolvedTool.rawValue   // G2

        var process: Process!
        var lastLaunchError: Error?

        for attempt in 1...2 {
            process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", wrapper]
            process.environment = mergedEnv
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = watch ? FileHandle.standardOutput : FileHandle.nullDevice
            process.standardError  = watch ? FileHandle.standardError  : FileHandle.nullDevice

            do {
                try process.run()
                lastLaunchError = nil
                break
            } catch let error as NSError {
                lastLaunchError = error
                if attempt == 2 { break }
                // DI2: only retry for transport-level errors that haven't
                // written any bytes to our logs yet.
                let retryable = isTransportLaunchErrno(error)
                    && stdoutLogIsUntouched(path: stdoutLog)
                if !retryable { break }
            }
        }

        if let err = lastLaunchError {
            // Update state to failed before throwing; caller may still
            // resume_session_id to diagnose.
            let failureNow = ISO8601DateFormatter().string(from: Date())
            try? SpecRunStateStore.update(sessionId: sessionId) { s in
                s.status = "failed"
                s.lastError = "delegateLaunchFailed: \(err)"
                s.completedAt = failureNow
            }
            throw ValidationError(L10n.SpecRun.delegateLaunchFailed("\(err)"))
        }

        // MARK: 11. watch vs detached
        if watch {
            process.waitUntilExit()
            // After wrapper exits it already called `_spec-finalize`, so
            // reload the final state.
            let latest = try SpecRunStateStore.load(sessionId: sessionId)
            return SpecRunResult.fromImplementState(latest)
        } else {
            // Detached: return the initial "running" shape; actual delegate
            // progress is observable via orrery_spec_status polling.
            return SpecRunResult.fromImplementState(state)
        }
    }

    // MARK: - Wrapper construction (exposed internal for testing)

    /// Build the `bash -c` wrapper string. Exposed (`internal`) so tests can
    /// assert on the string format without spawning a real subprocess.
    static func buildWrapperShell(
        delegateArgs: [String],
        stdoutLog: String,
        stderrLog: String,
        sessionId: String,
        overallTimeout: TimeInterval
    ) -> String {
        let orreryBin = resolveOrreryBinaryPath()
        let cmdQuoted = delegateArgs.map(shellQuote).joined(separator: " ")
        let stdoutLogQ = shellQuote(stdoutLog)
        let stderrLogQ = shellQuote(stderrLog)
        let orreryQ = shellQuote(orreryBin)
        let sessionQ = shellQuote(sessionId)
        let timeoutSec = max(0, Int(overallTimeout))

        let watchdogOpen: String
        let watchdogClose: String
        if timeoutSec > 0 {
            watchdogOpen = """
                ( sleep \(timeoutSec) && kill -TERM $DELEGATE_PID 2>/dev/null ) &
                WATCHDOG_PID=$!
                """
            watchdogClose = "kill $WATCHDOG_PID 2>/dev/null || true"
        } else {
            watchdogOpen = ""
            watchdogClose = ""
        }

        return """
            \(cmdQuoted) </dev/null >>\(stdoutLogQ) 2>>\(stderrLogQ) &
            DELEGATE_PID=$!
            \(watchdogOpen)
            wait $DELEGATE_PID
            RC=$?
            \(watchdogClose)
            \(orreryQ) _spec-finalize \(sessionQ) "$RC" </dev/null >/dev/null 2>&1 || true
            """
    }

    /// Classic POSIX single-quote escape: wrap in `'...'`, replace embedded `'`
    /// with `'\''` (close, escape, reopen). Safe for any non-control-character
    /// payload. Delegate prompts can be large — bash ARG_MAX is typically
    /// 256KB on macOS 14, well above claude-code prompt sizes.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// G3: resolve `arguments[0]` to an absolute path when possible.
    /// Fallback to the bare name `"orrery"` relying on PATH inheritance —
    /// works for homebrew / system install but not for `swift run` without
    /// first `swift build --package-path ...`.
    static func resolveOrreryBinaryPath() -> String {
        let raw = ProcessInfo.processInfo.arguments.first ?? "orrery"
        if raw.hasPrefix("/") { return raw }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resolved = URL(fileURLWithPath: raw, relativeTo: cwd).standardizedFileURL.path
        if FileManager.default.isExecutableFile(atPath: resolved) {
            return resolved
        }
        return "orrery"
    }

    // MARK: - Internal helpers

    private static func resolveSpecPath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd)
            .appendingPathComponent(path)
            .standardizedFileURL
            .path
    }

    private static func firstAvailableTool() throws -> Tool {
        for tool in Tool.allCases where isToolAvailable(tool) {
            return tool
        }
        throw ValidationError(L10n.Spec.noToolAvailable)
    }

    private static func isToolAvailable(_ tool: Tool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", tool.rawValue]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func isTransportLaunchErrno(_ error: NSError) -> Bool {
        // POSIX errno codes that indicate the subprocess never actually
        // started (vs semantic failures like non-zero exit).
        let transportErrnos: Set<Int32> = [EACCES, ENOENT, ETXTBSY, ENOEXEC, EISDIR]
        let code = Int32(error.code)
        if error.domain == NSPOSIXErrorDomain && transportErrnos.contains(code) {
            return true
        }
        // Foundation sometimes wraps launch errors with NSError.code == Int(errno).
        return transportErrnos.contains(code)
    }

    private static func stdoutLogIsUntouched(path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else {
            return true   // file doesn't exist yet = definitely untouched
        }
        return size == 0
    }

    private static func stderrWarn(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
