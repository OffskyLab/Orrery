import XCTest
@testable import OrreryCore

final class SpecFinalizeCommandTests: XCTestCase {

    private var tmpHome: URL!
    private var savedHome: String?

    override func setUp() {
        super.setUp()
        tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-finalize-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        savedHome = ProcessInfo.processInfo.environment["ORRERY_HOME"]
        setenv("ORRERY_HOME", tmpHome.path, 1)
    }

    override func tearDown() {
        if let saved = savedHome {
            setenv("ORRERY_HOME", saved, 1)
        } else {
            unsetenv("ORRERY_HOME")
        }
        try? FileManager.default.removeItem(at: tmpHome)
        super.tearDown()
    }

    private func runFinalize(sessionId: String, exitCode: Int32) throws {
        var cmd = SpecFinalizeCommand()
        cmd.sessionId = sessionId
        cmd.exitCode = exitCode
        try cmd.run()
    }

    private func seedRunningState(
        _ sessionId: String = UUID().uuidString,
        preSnapshot: [String] = [],
        delegateId: String? = nil
    ) throws -> String {
        var state = SpecRunState.initial(sessionId: sessionId, startedAt: "2026-04-22T00:00:00Z")
        state.preSessionSnapshot = preSnapshot
        state.delegateSessionId = delegateId
        try SpecRunStateStore.write(sessionId: sessionId, state: state)
        return sessionId
    }

    // MARK: - Missing session no-op

    func testMissingSession_isSilentNoOp_exits0() throws {
        // Should not throw, should not create state, should not crash.
        XCTAssertNoThrow(
            try runFinalize(sessionId: "nonexistent-\(UUID().uuidString)", exitCode: 0)
        )
    }

    // MARK: - G5 idempotency

    func testIdempotency_terminalStateIsNotOverwritten() throws {
        let sid = try seedRunningState()
        // Manually mark terminal with a specific lastError we can check is preserved
        try SpecRunStateStore.update(sessionId: sid) { s in
            s.status = "done"
            s.completedAt = "2026-04-22T00:05:00Z"
            s.lastError = "prior-final-state"
        }
        let before = try SpecRunStateStore.load(sessionId: sid)

        // Second finalize with a different exit code — should be ignored
        try runFinalize(sessionId: sid, exitCode: 1)

        let after = try SpecRunStateStore.load(sessionId: sid)
        XCTAssertEqual(after.status, "done", "terminal state must survive re-finalize")
        XCTAssertEqual(after.lastError, "prior-final-state")
        XCTAssertEqual(after.completedAt, before.completedAt)
    }

    // MARK: - Exit code → status mapping

    func testExitCode0_mapsToDone() throws {
        let sid = try seedRunningState()
        try runFinalize(sessionId: sid, exitCode: 0)
        let state = try SpecRunStateStore.load(sessionId: sid)
        XCTAssertEqual(state.status, "done")
        XCTAssertNotNil(state.completedAt)
        XCTAssertNil(state.lastError)
    }

    func testExitCode143_mapsToAborted_withTimeoutReason() throws {
        let sid = try seedRunningState()
        try runFinalize(sessionId: sid, exitCode: 143)
        let state = try SpecRunStateStore.load(sessionId: sid)
        XCTAssertEqual(state.status, "aborted")
        XCTAssertEqual(state.blockedReason, "overall timeout")
    }

    func testExitCodeNonZero_mapsToFailed_withLastError() throws {
        let sid = try seedRunningState()
        // Write some stderr log content so finalize can capture the tail
        let stderrPath = SpecRunStateStore.stderrLogPath(sessionId: sid).path
        try "compile error: foo.swift:42: undefined identifier 'bar'\n"
            .write(toFile: stderrPath, atomically: true, encoding: .utf8)

        try runFinalize(sessionId: sid, exitCode: 2)

        let state = try SpecRunStateStore.load(sessionId: sid)
        XCTAssertEqual(state.status, "failed")
        XCTAssertNotNil(state.lastError)
        XCTAssertTrue(state.lastError?.contains("exit=2") == true)
        XCTAssertTrue(state.lastError?.contains("compile error") == true)
    }

    func testExitCodeNonZero_withoutStderrLog_stillSetsLastError() throws {
        let sid = try seedRunningState()
        try runFinalize(sessionId: sid, exitCode: 3)
        let state = try SpecRunStateStore.load(sessionId: sid)
        XCTAssertEqual(state.status, "failed")
        XCTAssertEqual(state.lastError, "exit=3")
    }

    // MARK: - Progress log integration

    func testProgressLog_populatesCompletedStepsAndFailedStep() throws {
        let sid = try seedRunningState()
        // Write a progress log with one done and one unclosed start
        let progressPath = SpecRunStateStore.progressLogPath(sessionId: sid).path
        let lines = [
            "{\"ts\":\"2026-04-22T00:01:00Z\",\"step\":\"step-1\",\"event\":\"start\"}",
            "{\"ts\":\"2026-04-22T00:02:00Z\",\"step\":\"step-1\",\"event\":\"done\"}",
            "{\"ts\":\"2026-04-22T00:03:00Z\",\"step\":\"step-2\",\"event\":\"start\"}"
        ]
        try lines.joined(separator: "\n").write(toFile: progressPath, atomically: true, encoding: .utf8)

        try runFinalize(sessionId: sid, exitCode: 2)

        let state = try SpecRunStateStore.load(sessionId: sid)
        XCTAssertEqual(state.completedSteps, ["step-1"])
        XCTAssertEqual(state.failedStep, "step-2")
        XCTAssertEqual(state.status, "failed")
    }

    func testProgressLog_emptyDoesNotBreakFinalize() throws {
        let sid = try seedRunningState()
        // Create an empty progress log file
        let progressPath = SpecRunStateStore.progressLogPath(sessionId: sid).path
        try "".write(toFile: progressPath, atomically: true, encoding: .utf8)

        XCTAssertNoThrow(try runFinalize(sessionId: sid, exitCode: 0))
        let state = try SpecRunStateStore.load(sessionId: sid)
        XCTAssertEqual(state.status, "done")
        XCTAssertEqual(state.completedSteps, [])
        XCTAssertNil(state.failedStep)
    }

    func testProgressLog_missingFile_doesNotBreakFinalize() throws {
        let sid = try seedRunningState()
        // No progress log at all
        XCTAssertNoThrow(try runFinalize(sessionId: sid, exitCode: 0))
        let state = try SpecRunStateStore.load(sessionId: sid)
        XCTAssertEqual(state.status, "done")
    }

    // MARK: - Git diff capture (passive)

    func testGitCapture_populatesTouchedFiles_inRepoContext() throws {
        // Finalize is already running in a repo (the orrery repo itself),
        // so `git diff --name-only` should succeed. We can't easily assert
        // specific files, but we CAN assert the runner doesn't blow up and
        // that touched_files is set (may be empty if the worktree is clean).
        let sid = try seedRunningState()
        try runFinalize(sessionId: sid, exitCode: 0)
        let state = try SpecRunStateStore.load(sessionId: sid)
        // diffSummary and touchedFiles are both populated (possibly empty
        // collections) — NOT left nil.
        XCTAssertNotNil(state.diffSummary)
        // touchedFiles is [String], not Optional — always non-nil
    }

    // MARK: - State integrity: delegate_session_id preserved when no tool env

    func testNoOrrerySpecTool_envSkipsDelegateDiff_butFinalizeSucceeds() throws {
        let sid = try seedRunningState(delegateId: "prior-delegate-id")
        // Explicitly clear env so tool resolution fails
        unsetenv("ORRERY_SPEC_TOOL")

        try runFinalize(sessionId: sid, exitCode: 0)

        let state = try SpecRunStateStore.load(sessionId: sid)
        XCTAssertEqual(state.status, "done")
        // Delegate id should not be clobbered just because we couldn't diff
        XCTAssertEqual(state.delegateSessionId, "prior-delegate-id")
    }

    // MARK: - Terminal updates stamp updatedAt

    func testFinalize_stampsCompletedAtAndUpdatedAt() throws {
        let sid = try seedRunningState()
        let before = try SpecRunStateStore.load(sessionId: sid)
        XCTAssertNil(before.completedAt)

        try runFinalize(sessionId: sid, exitCode: 0)

        let after = try SpecRunStateStore.load(sessionId: sid)
        XCTAssertNotNil(after.completedAt)
        XCTAssertNotEqual(after.updatedAt, before.updatedAt,
                          "updatedAt should be refreshed post-finalize")
    }
}
