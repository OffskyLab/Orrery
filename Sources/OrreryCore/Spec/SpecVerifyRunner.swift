import ArgumentParser
import Foundation

/// Orchestrates the `verify` phase of `orrery spec-run`: parse the spec,
/// apply the sandbox policy, execute acceptance commands (or simulate them
/// in dry-run), collect structured outcomes, and optionally spawn an
/// advisory Magi review.
///
/// MVP scope (D15): verify only; no AI agent session for the runner itself
/// (see spec Step 4.6) — only `--review` spawns a subprocess.
public struct SpecVerifyRunner {

    public static func run(
        specPath: String,
        tool: Tool?,
        environment: String?,
        store: EnvironmentStore,
        execute: Bool,
        strictPolicy: Bool,
        perCommandTimeout: TimeInterval,
        overallTimeout: TimeInterval,
        review: Bool,
        resumeSessionId: String?
    ) throws -> SpecRunResult {
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let resolvedPath = resolve(path: specPath)

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            throw ValidationError(L10n.SpecRun.specNotFound(resolvedPath))
        }

        let markdown = try String(contentsOfFile: resolvedPath, encoding: .utf8)
        let (checklistItems, commands) = try SpecAcceptanceParser.parse(markdown: markdown)

        var stderrLog: [String] = []
        stderrLog.append("verify MVP runs locally without agent session")
        if let rid = resumeSessionId {
            stderrLog.append(L10n.SpecRun.verifyFreshSession(rid))
        }

        // Checklist is prose — MVP cannot auto-verify, mark all skipped.
        let checklistOutcomes: [ChecklistOutcome] = checklistItems.map {
            ChecklistOutcome(
                item: $0.text,
                status: .skipped,
                evidence: "manual review required"
            )
        }

        let commandOutcomes: [CommandOutcome]
        if execute {
            commandOutcomes = runCommands(
                commands: commands,
                perCommandTimeout: perCommandTimeout,
                overallTimeout: overallTimeout
            )
        } else {
            commandOutcomes = commands.map {
                CommandOutcome(
                    command: $0.line,
                    status: .skipped,
                    exitCode: 0,
                    stdoutSnippet: "",
                    stderrSnippet: "",
                    durationMs: 0,
                    skippedReason: "dry-run"
                )
            }
        }

        let policyBlockedCount = commandOutcomes.filter { $0.status == .policyBlocked }.count
        if policyBlockedCount > 0 {
            stderrLog.append(L10n.SpecRun.policyBlockedSummary(policyBlockedCount))
        }

        let diffSummary = collectDiffStat()

        let reviewOutcome: ReviewOutcome? = makeReviewOutcome(
            requested: review,
            commandOutcomes: commandOutcomes,
            strictPolicy: strictPolicy,
            specPath: resolvedPath,
            tool: tool,
            environment: environment,
            store: store
        )

        let summary = buildSummary(
            checklist: checklistOutcomes,
            commands: commandOutcomes,
            policyBlockedCount: policyBlockedCount,
            execute: execute,
            review: reviewOutcome
        )

        let completedAt = ISO8601DateFormatter().string(from: Date())
        // Derive a coarse implement-style status for cross-phase clients:
        //   any fail -> "failed", any policy_blocked under strict -> "failed",
        //   otherwise -> "done" (dry-run and all-pass both land here).
        let hasFail = commandOutcomes.contains { $0.status == .fail }
        let hasBlocked = commandOutcomes.contains { $0.status == .policyBlocked }
        let verifyStatus: String = hasFail || (strictPolicy && hasBlocked) ? "failed" : "done"

        return SpecRunResult(
            sessionId: nil,
            phase: "verify",
            completedSteps: execute ? ["parsed", "executed"] : ["parsed", "dry-run"],
            verification: VerificationResult(
                checklist: checklistOutcomes,
                testResults: commandOutcomes
            ),
            summaryMarkdown: summary,
            stderr: stderrLog.joined(separator: "\n"),
            diffSummary: diffSummary,
            review: reviewOutcome,
            error: nil,
            status: verifyStatus,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    // MARK: - Path resolution (M5)

    private static func resolve(path: String) -> String {
        if path.hasPrefix("/") { return path }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd)
            .appendingPathComponent(path)
            .standardizedFileURL
            .path
    }

    // MARK: - Command execution loop

    private static func runCommands(
        commands: [SpecAcceptanceParser.Command],
        perCommandTimeout: TimeInterval,
        overallTimeout: TimeInterval
    ) -> [CommandOutcome] {
        var results: [CommandOutcome] = []
        let overallStart = Date()
        var overallExceeded = false

        for command in commands {
            if overallExceeded {
                results.append(CommandOutcome(
                    command: command.line,
                    status: .skipped,
                    exitCode: 0,
                    stdoutSnippet: "",
                    stderrSnippet: "",
                    durationMs: 0,
                    skippedReason: "overall timeout"
                ))
                continue
            }

            if Date().timeIntervalSince(overallStart) > overallTimeout {
                overallExceeded = true
                results.append(CommandOutcome(
                    command: command.line,
                    status: .skipped,
                    exitCode: 0,
                    stdoutSnippet: "",
                    stderrSnippet: "",
                    durationMs: 0,
                    skippedReason: "overall timeout"
                ))
                continue
            }

            let decision = SpecSandboxPolicy.decide(command: command.line)
            switch decision {
            case .blocked(let reason):
                results.append(CommandOutcome(
                    command: command.line,
                    status: .policyBlocked,
                    exitCode: 0,
                    stdoutSnippet: "",
                    stderrSnippet: "",
                    durationMs: 0,
                    skippedReason: reason
                ))
            case .allowed:
                results.append(executeOne(
                    command: command.line,
                    perCommandTimeout: perCommandTimeout
                ))
            }
        }
        return results
    }

    private static func executeOne(
        command: String,
        perCommandTimeout: TimeInterval
    ) -> CommandOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        // Drain pipes on background threads before process.run() so a large
        // output stream cannot deadlock the child (pipe buffer ~64KB).
        var stdoutData = Data()
        var stdoutTruncated = false
        var stderrData = Data()
        var stderrTruncated = false
        let readGroup = DispatchGroup()

        readGroup.enter()
        DispatchQueue.global().async {
            (stdoutData, stdoutTruncated) = readCapped(
                handle: stdoutPipe.fileHandleForReading,
                cap: SpecSandboxPolicy.stdoutByteCap
            )
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global().async {
            (stderrData, stderrTruncated) = readCapped(
                handle: stderrPipe.fileHandleForReading,
                cap: SpecSandboxPolicy.stdoutByteCap
            )
            readGroup.leave()
        }

        let timeoutWork = DispatchWorkItem { [process] in
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + perCommandTimeout,
            execute: timeoutWork
        )

        let start = Date()
        do {
            try process.run()
        } catch {
            timeoutWork.cancel()
            return CommandOutcome(
                command: command,
                status: .fail,
                exitCode: -1,
                stdoutSnippet: "",
                stderrSnippet: "Failed to launch: \(error)",
                durationMs: 0,
                skippedReason: nil
            )
        }

        process.waitUntilExit()
        timeoutWork.cancel()
        readGroup.wait()

        let duration = Date().timeIntervalSince(start)
        let timedOut = process.terminationReason == .uncaughtSignal
            && process.terminationStatus == 15 // SIGTERM

        let exitCode = process.terminationStatus
        let status: OutcomeStatus = (exitCode == 0 && !timedOut) ? .pass : .fail

        var stdoutSnippet = String(data: stdoutData, encoding: .utf8) ?? ""
        if stdoutTruncated { stdoutSnippet += "…[truncated]" }
        var stderrSnippet = String(data: stderrData, encoding: .utf8) ?? ""
        if stderrTruncated { stderrSnippet += "…[truncated]" }
        if timedOut {
            stderrSnippet += (stderrSnippet.isEmpty ? "" : "\n")
            stderrSnippet += "[killed: per-command timeout exceeded]"
        }

        return CommandOutcome(
            command: command,
            status: status,
            exitCode: exitCode,
            stdoutSnippet: stdoutSnippet,
            stderrSnippet: stderrSnippet,
            durationMs: Int(duration * 1000),
            skippedReason: nil
        )
    }

    /// Read from a pipe up to `cap` bytes, then keep draining to prevent the
    /// child from blocking on a full pipe buffer. Returns (data, truncated).
    private static func readCapped(
        handle: FileHandle,
        cap: Int
    ) -> (Data, Bool) {
        var accumulated = Data()
        var truncated = false
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if accumulated.count >= cap {
                truncated = true
                continue
            }
            let remaining = cap - accumulated.count
            if chunk.count <= remaining {
                accumulated.append(chunk)
            } else {
                accumulated.append(chunk.prefix(remaining))
                truncated = true
            }
        }
        return (accumulated, truncated)
    }

    // MARK: - git diff --stat

    private static func collectDiffStat() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "diff", "--stat"]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    // MARK: - Review

    private static func makeReviewOutcome(
        requested: Bool,
        commandOutcomes: [CommandOutcome],
        strictPolicy: Bool,
        specPath: String,
        tool: Tool?,
        environment: String?,
        store: EnvironmentStore
    ) -> ReviewOutcome? {
        guard requested else { return nil }

        let hasFail = commandOutcomes.contains { $0.status == .fail }
        let hasBlocked = commandOutcomes.contains { $0.status == .policyBlocked }
        let verifyPassed = !hasFail && (!strictPolicy || !hasBlocked)

        guard verifyPassed else {
            return ReviewOutcome(
                verdict: .advisoryOnly,
                reasoning: "verify did not fully pass; review skipped",
                flaggedItems: []
            )
        }

        return invokeMagiReview(specPath: specPath)
    }

    private static func invokeMagiReview(specPath: String) -> ReviewOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let topic = "Review spec at \(specPath): are the acceptance criteria "
            + "complete, realistic, and consistent with the stated 改動檔案 "
            + "and 介面合約 sections?"
        process.arguments = ["orrery", "magi", "--rounds", "1", topic]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            // Drain both pipes concurrently to avoid the child blocking on a
            // full stderr buffer while we wait on stdout.
            var outData = Data()
            var errData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            try process.run()
            process.waitUntilExit()
            group.wait()

            if process.terminationStatus != 0 {
                let stderrMsg = String(data: errData, encoding: .utf8) ?? ""
                let trimmed = String(stderrMsg.suffix(300))
                return ReviewOutcome(
                    verdict: .advisoryOnly,
                    reasoning: "magi review unavailable: \(trimmed)",
                    flaggedItems: []
                )
            }

            let output = String(data: outData, encoding: .utf8) ?? ""
            // Heuristic: every sub-topic tagged `[agreed]` and none `[disputed]`
            // → pass. Anything else is a soft fail (advisory only).
            let lower = output.lowercased()
            let hasAgreed = lower.contains("[agreed]")
            let hasDisputed = lower.contains("[disputed]")
            let verdict: ReviewOutcome.Verdict =
                (hasAgreed && !hasDisputed) ? .pass : .fail
            let reasoning = String(output.suffix(500))
            return ReviewOutcome(
                verdict: verdict,
                reasoning: reasoning,
                flaggedItems: []
            )
        } catch {
            return ReviewOutcome(
                verdict: .advisoryOnly,
                reasoning: "magi review unavailable: \(error)",
                flaggedItems: []
            )
        }
    }

    // MARK: - Summary

    private static func buildSummary(
        checklist: [ChecklistOutcome],
        commands: [CommandOutcome],
        policyBlockedCount: Int,
        execute: Bool,
        review: ReviewOutcome?
    ) -> String {
        var lines: [String] = []
        lines.append("# Verify Summary")
        lines.append("")
        lines.append("- Checklist items: \(checklist.count) (all `skipped` — manual review required)")

        let passCount = commands.filter { $0.status == .pass }.count
        let failCount = commands.filter { $0.status == .fail }.count
        let skippedCount = commands.filter { $0.status == .skipped }.count
        lines.append("- Commands: \(commands.count) total — "
            + "pass=\(passCount), fail=\(failCount), skipped=\(skippedCount), "
            + "policy_blocked=\(policyBlockedCount)")

        if !execute {
            lines.append("- Mode: **dry-run** (no shell commands executed; pass `--execute` to run)")
        }

        if let firstFail = commands.first(where: { $0.status == .fail }) {
            lines.append("")
            lines.append("## First failure")
            lines.append("")
            lines.append("```")
            lines.append("$ \(firstFail.command)")
            lines.append("exit=\(firstFail.exitCode) duration=\(firstFail.durationMs)ms")
            if !firstFail.stderrSnippet.isEmpty {
                lines.append("-- stderr --")
                lines.append(firstFail.stderrSnippet)
            }
            lines.append("```")
        }

        let blocked = commands.filter { $0.status == .policyBlocked }
        if !blocked.isEmpty {
            lines.append("")
            lines.append("## Policy-blocked commands (not executed)")
            lines.append("")
            for b in blocked {
                lines.append("- `\(b.command)` — reason: \(b.skippedReason ?? "")")
            }
            lines.append("")
            lines.append("If you need to run these, review and execute manually.")
        }

        if let r = review {
            lines.append("")
            lines.append("## Review")
            lines.append("")
            lines.append("- verdict: `\(r.verdict.rawValue)`")
            if !r.reasoning.isEmpty {
                lines.append("- reasoning (excerpt): \(r.reasoning.prefix(200))…")
            }
        }

        return lines.joined(separator: "\n")
    }
}
