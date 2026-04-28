import ArgumentParser
import Foundation

/// Hidden subcommand `orrery _spec-finalize <session_id> <exit_code>`.
///
/// Not listed in `orrery --help` (`shouldDisplay: false`); designed to be
/// invoked only by the wrapper shell spawned by `SpecImplementRunner` after
/// the delegate subprocess exits. It:
///
/// 1. Loads the session state file.
/// 2. (G5) If already terminal → no-op with stderr note.
/// 3. Takes a postSnapshot of scoped sessions and diffs against the
///    stored `preSessionSnapshot` to capture `delegate_session_id`.
/// 4. Reads the progress jsonl → `completed_steps` + `failed_step`.
/// 5. Runs `git diff --stat` / `git diff --name-only` → `diff_summary` /
///    `touched_files`.
/// 6. Maps the wrapper's exit code → `status` (`done` / `aborted` / `failed`).
/// 7. Writes the final state and exits 0.
///
/// Never throws to the caller — wrappers don't check the exit code and we
/// don't want to surface finalize errors as delegate failures.
public struct SpecFinalizeCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_spec-finalize",
        abstract: L10n.SpecRun.finalizeAbstract,
        shouldDisplay: false
    )

    @Argument public var sessionId: String
    @Argument public var exitCode: Int32

    public init() {}

    public func run() throws {
        // Guarded `run()` — we catch EVERYTHING and exit 0 so a finalize
        // failure cannot mask the delegate's real outcome for the user.
        // Internal errors go to stderr for later forensics.
        do {
            try finalize()
        } catch {
            warn("_spec-finalize internal error for session=\(sessionId): \(error)")
        }
    }

    // MARK: - Main finalize flow

    private func finalize() throws {
        // 1. Load state; missing file = silent no-op (防呆)
        guard SpecRunStateStore.exists(sessionId: sessionId) else {
            warn("_spec-finalize called for unknown session=\(sessionId); skipping")
            return
        }
        var state = try SpecRunStateStore.load(sessionId: sessionId)

        // 2. G5 idempotency guard
        let terminalStatuses: Set<String> = ["done", "failed", "aborted"]
        if terminalStatuses.contains(state.status) {
            warn(
                "finalize called twice for session=\(sessionId); "
                + "state already \(state.status), skipping"
            )
            return
        }

        // 3. postSnapshot diff → delegate_session_id
        if let tool = resolveTool() {
            let post = SessionResolver.findScopedSessions(
                tool: tool,
                cwd: FileManager.default.currentDirectoryPath,
                store: .default,
                activeEnvironment: ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
            ).map(\.id)

            let preSet = Set(state.preSessionSnapshot)
            let postSet = Set(post)
            let diff = postSet.subtracting(preSet)
            if diff.count == 1, let newId = diff.first {
                state.delegateSessionId = newId
            } else if diff.count > 1 {
                warn(
                    "ambiguous delegate session diff for session=\(sessionId): "
                    + "\(diff.count) new ids — leaving delegate_session_id as prior value"
                )
            }
            // diff.count == 0 → delegate didn't create a new session (e.g.
            // launch failed silently); leave delegateSessionId as whatever
            // prior held (typically nil).
        } else {
            warn(
                "ORRERY_SPEC_TOOL not set and tool inference failed; "
                + "skipping delegate_session_id capture for session=\(sessionId)"
            )
        }

        // 4. Progress log → completed_steps / failed_step
        let progressPath = SpecRunStateStore.progressLogPath(sessionId: sessionId).path
        let events = (try? SpecProgressLog.read(path: progressPath)) ?? []
        if !events.isEmpty {
            state.completedSteps = SpecProgressLog.completedSteps(events: events)
            state.failedStep = SpecProgressLog.inferFailedStep(events: events)
        } else if FileManager.default.fileExists(atPath: progressPath) {
            warn(
                "progress log empty/corrupted for session=\(sessionId); "
                + "failed_step unknown"
            )
        }
        // progress log missing entirely → delegate likely never started
        // step-boundary reporting; leave completed_steps/failed_step at
        // their current values (empty / nil).

        // 5. git diff — passive observation only (DI6: no self-check)
        state.diffSummary = runGitCapture(args: ["diff", "--stat"])
        let diffNames = runGitCapture(args: ["diff", "--name-only"])
        state.touchedFiles = diffNames
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        // 6. Map wrapper exit code → status
        let nowIso = ISO8601DateFormatter().string(from: Date())
        state.completedAt = nowIso

        if exitCode == 0 {
            state.status = "done"
        } else if exitCode == 143 || state.blockedReason == "overall timeout" {
            // 143 = 128 + SIGTERM(15); wrapper watchdog fires SIGTERM on timeout
            state.status = "aborted"
            if state.blockedReason == nil {
                state.blockedReason = "overall timeout"
            }
        } else {
            state.status = "failed"
            // Capture last ~2KB of stderr log as the failure hint.
            let stderrLog = SpecRunStateStore.stderrLogPath(sessionId: sessionId).path
            if let tail = readTail(path: stderrLog, maxBytes: 2048), !tail.isEmpty {
                state.lastError = "exit=\(exitCode): \(tail)"
            } else {
                state.lastError = "exit=\(exitCode)"
            }
        }

        // 7. Write (update() would restamp updatedAt via its mutate wrapper
        // but we want completedAt + status to go out atomically; write() is
        // fine since we just read state above).
        state.updatedAt = nowIso
        try SpecRunStateStore.write(sessionId: sessionId, state: state)
    }

    // MARK: - Helpers

    /// Prefer `ORRERY_SPEC_TOOL` env (injected by SpecImplementRunner);
    /// otherwise return nil — caller will skip the delegate-session diff.
    private func resolveTool() -> Tool? {
        if let raw = ProcessInfo.processInfo.environment["ORRERY_SPEC_TOOL"],
           let tool = Tool(rawValue: raw) {
            return tool
        }
        return nil
    }

    /// Run `git <args>` and capture stdout. Returns "" on any error — finalize
    /// must not explode if the working directory isn't a git repo.
    private func runGitCapture(args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    /// Read the last `maxBytes` bytes of a file, best-effort. Returns nil on
    /// any I/O failure.
    private func readTail(path: String, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }

        do {
            let end = try handle.seekToEnd()
            let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
            try handle.seek(toOffset: start)
            let data = handle.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
