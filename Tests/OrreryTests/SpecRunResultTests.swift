import XCTest
@testable import OrreryCore

final class SpecRunResultTests: XCTestCase {

    // MARK: - Extended fields presence in JSON (schema stability)

    func testVerifyResultStillEncodesAllFieldsIncludingNewOnes() throws {
        // verify uses the default values for implement-phase fields
        let result = SpecRunResult(
            sessionId: nil,
            phase: "verify",
            completedSteps: ["parsed", "dry-run"],
            verification: VerificationResult(checklist: [], testResults: []),
            summaryMarkdown: "",
            stderr: "",
            diffSummary: "",
            review: nil,
            error: nil
            // status, startedAt, completedAt, touchedFiles, blockedReason,
            // failedStep, childSessionIds, executionGraph = defaults
        )
        let json = try result.toJSONString()
        let parsed = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
        let keys = Set(parsed.keys)

        // Original verify keys still present
        XCTAssertTrue(keys.contains("session_id"))
        XCTAssertTrue(keys.contains("phase"))
        XCTAssertTrue(keys.contains("completed_steps"))
        XCTAssertTrue(keys.contains("verification"))
        XCTAssertTrue(keys.contains("summary_markdown"))
        XCTAssertTrue(keys.contains("stderr"))
        XCTAssertTrue(keys.contains("diff_summary"))
        XCTAssertTrue(keys.contains("review"))
        XCTAssertTrue(keys.contains("error"))

        // New implement-phase keys also present (with default values)
        XCTAssertTrue(keys.contains("status"))
        XCTAssertTrue(keys.contains("started_at"))
        XCTAssertTrue(keys.contains("completed_at"))
        XCTAssertTrue(keys.contains("touched_files"))
        XCTAssertTrue(keys.contains("blocked_reason"))
        XCTAssertTrue(keys.contains("failed_step"))
        XCTAssertTrue(keys.contains("child_session_ids"))
        XCTAssertTrue(keys.contains("execution_graph"))
    }

    func testVerifyResult_newNilFieldsAppearAsExplicitNull() throws {
        let result = SpecRunResult(
            sessionId: nil, phase: "verify", completedSteps: [],
            verification: VerificationResult(checklist: [], testResults: []),
            summaryMarkdown: "", stderr: "", diffSummary: nil,
            review: nil, error: nil
        )
        let json = try result.toJSONString()
        XCTAssertTrue(json.contains("\"completed_at\" : null") || json.contains("\"completed_at\": null"))
        XCTAssertTrue(json.contains("\"blocked_reason\" : null") || json.contains("\"blocked_reason\": null"))
        XCTAssertTrue(json.contains("\"failed_step\" : null") || json.contains("\"failed_step\": null"))
        XCTAssertTrue(json.contains("\"execution_graph\" : null") || json.contains("\"execution_graph\": null"))
    }

    // MARK: - errorShell new defaults

    func testErrorShell_nowStampsStartedAtAndCompletedAt() throws {
        let shell = SpecRunResult.errorShell(phase: "implement", error: "boom")
        XCTAssertEqual(shell.phase, "implement")
        XCTAssertEqual(shell.error, "boom")
        XCTAssertEqual(shell.status, "failed")
        XCTAssertFalse(shell.startedAt.isEmpty, "errorShell should stamp started_at")
        XCTAssertFalse(shell.completedAt ?? "" == "", "errorShell should stamp completed_at")
        // Both stamps should be ISO8601-ish
        XCTAssertTrue(shell.startedAt.contains("T"))
        XCTAssertTrue(shell.startedAt.contains("Z"))
    }

    // MARK: - fromImplementState factory

    func testFromImplementState_copiesAllImplementFields() {
        let state = SpecRunState(
            sessionId: "sid-abc",
            delegateSessionId: "delegate-xyz",
            preSessionSnapshot: ["old-1"],
            phase: "implement",
            status: "done",
            startedAt: "2026-04-22T00:00:00Z",
            updatedAt: "2026-04-22T00:05:00Z",
            completedAt: "2026-04-22T00:05:00Z",
            completedSteps: ["step-1", "step-2"],
            touchedFiles: ["Foo.swift"],
            diffSummary: "1 file changed",
            blockedReason: nil,
            failedStep: nil,
            childSessionIds: [],
            executionGraph: nil,
            lastError: nil
        )
        let r = SpecRunResult.fromImplementState(state)
        XCTAssertEqual(r.sessionId, "sid-abc")
        XCTAssertEqual(r.phase, "implement")
        XCTAssertEqual(r.status, "done")
        XCTAssertEqual(r.startedAt, "2026-04-22T00:00:00Z")
        XCTAssertEqual(r.completedAt, "2026-04-22T00:05:00Z")
        XCTAssertEqual(r.completedSteps, ["step-1", "step-2"])
        XCTAssertEqual(r.touchedFiles, ["Foo.swift"])
        XCTAssertEqual(r.diffSummary, "1 file changed")
        XCTAssertNil(r.failedStep)
        XCTAssertNil(r.blockedReason)
    }

    func testFromImplementState_doesNotLeakInternalDelegateSessionId() throws {
        // C2: delegateSessionId / preSessionSnapshot are internal bookkeeping
        // and must not appear in the outbound JSON.
        let state = SpecRunState(
            sessionId: "sid",
            delegateSessionId: "SECRET-DELEGATE-ID",
            preSessionSnapshot: ["SECRET-PRE-1"],
            startedAt: "t", updatedAt: "t"
        )
        let json = try SpecRunResult.fromImplementState(state).toJSONString()
        XCTAssertFalse(json.contains("SECRET-DELEGATE-ID"),
                       "delegateSessionId must not leak into outbound SpecRunResult")
        XCTAssertFalse(json.contains("SECRET-PRE-1"),
                       "preSessionSnapshot must not leak into outbound SpecRunResult")
        XCTAssertFalse(json.contains("delegate_session_id"))
        XCTAssertFalse(json.contains("pre_session_snapshot"))
    }

    func testFromImplementState_errorPopulatesFromLastError() {
        let state = SpecRunState(
            sessionId: "sid",
            status: "failed",
            startedAt: "t", updatedAt: "t",
            lastError: "compile fail"
        )
        let r = SpecRunResult.fromImplementState(state)
        XCTAssertEqual(r.error, "compile fail")
        XCTAssertEqual(r.status, "failed")
    }

    // MARK: - SpecStatusResult

    func testStatusResult_runningState_resultIsNil() throws {
        let state = SpecRunState(
            sessionId: "sid", startedAt: "2026-04-22T00:00:00Z", updatedAt: "2026-04-22T00:00:00Z"
        )
        // default status == "running"
        XCTAssertEqual(state.status, "running")

        let status = SpecStatusResult.from(state: state, logTail: [])
        XCTAssertNil(status.result)
        XCTAssertEqual(status.status, "running")
        XCTAssertEqual(status.sessionId, "sid")
    }

    func testStatusResult_terminalState_resultIsPopulated() throws {
        let state = SpecRunState(
            sessionId: "sid", status: "done",
            startedAt: "t", updatedAt: "t",
            completedAt: "t", completedSteps: ["a", "b"],
            touchedFiles: ["x.swift"]
        )
        let status = SpecStatusResult.from(state: state, logTail: ["raw-line-1", "raw-line-2"])
        XCTAssertNotNil(status.result)
        XCTAssertEqual(status.result?.status, "done")
        XCTAssertEqual(status.result?.touchedFiles, ["x.swift"])
        XCTAssertEqual(status.logTail, ["raw-line-1", "raw-line-2"])
    }

    func testStatusResult_failedStatePropagatesLastError() {
        let state = SpecRunState(
            sessionId: "sid", status: "failed",
            startedAt: "t", updatedAt: "t",
            lastError: "exit=1: compile error"
        )
        let status = SpecStatusResult.from(state: state, logTail: [])
        XCTAssertEqual(status.lastError, "exit=1: compile error")
        XCTAssertNotNil(status.result)
        XCTAssertEqual(status.result?.error, "exit=1: compile error")
    }

    func testStatusResult_progressSnapshotFromFailedStep() {
        let state = SpecRunState(
            sessionId: "sid", status: "failed",
            startedAt: "t", updatedAt: "t",
            completedSteps: ["step-1"],
            failedStep: "step-2"
        )
        let status = SpecStatusResult.from(state: state, logTail: [])
        XCTAssertEqual(status.progress.currentStep, "step-2")
        XCTAssertNil(status.progress.totalSteps) // MVP
    }

    func testStatusResult_runningProgressHintsLastCompletedStep() {
        let state = SpecRunState(
            sessionId: "sid", status: "running",
            startedAt: "t", updatedAt: "t",
            completedSteps: ["step-1"]
        )
        let status = SpecStatusResult.from(state: state, logTail: [])
        XCTAssertEqual(status.progress.currentStep, "after:step-1")
    }

    // MARK: - SpecStatusResult JSON schema

    func testStatusResult_jsonSchemaShape() throws {
        let state = SpecRunState(
            sessionId: "sid", startedAt: "t", updatedAt: "t"
        )
        let status = SpecStatusResult.from(state: state, logTail: [])
        let json = try status.toJSONString()
        let parsed = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
        let keys = Set(parsed.keys)
        for expected in ["session_id", "phase", "status", "started_at", "updated_at",
                         "progress", "last_error", "result", "log_tail"] {
            XCTAssertTrue(keys.contains(expected), "missing key: \(expected)")
        }

        // result nil when running — but key must be present
        XCTAssertTrue(json.contains("\"result\" : null") || json.contains("\"result\": null"))

        // progress sub-object
        let progress = parsed["progress"] as! [String: Any]
        XCTAssertTrue(progress.keys.contains("current_step"))
        XCTAssertTrue(progress.keys.contains("total_steps"))
    }

    // MARK: - Regression: non-nil new fields appear in JSON

    func testImplementResult_nonNilFieldsAppearInJSON() throws {
        let state = SpecRunState(
            sessionId: "abc", status: "aborted",
            startedAt: "t", updatedAt: "t",
            completedAt: "t2",
            touchedFiles: ["one.swift", "two.swift"],
            blockedReason: "overall timeout",
            failedStep: "step-7"
        )
        let json = try SpecRunResult.fromImplementState(state).toJSONString()
        XCTAssertTrue(json.contains("\"status\" : \"aborted\"") || json.contains("\"status\":\"aborted\""))
        XCTAssertTrue(json.contains("\"blocked_reason\" : \"overall timeout\"") ||
                      json.contains("\"blocked_reason\":\"overall timeout\""))
        XCTAssertTrue(json.contains("\"failed_step\" : \"step-7\"") ||
                      json.contains("\"failed_step\":\"step-7\""))
        XCTAssertTrue(json.contains("\"one.swift\"") && json.contains("\"two.swift\""))
    }
}
