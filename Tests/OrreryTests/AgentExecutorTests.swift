import XCTest
@testable import OrreryCore

/// Tests for the `AgentExecutor` protocol shape and a mock conformance.
/// The real `ProcessAgentExecutor` (T3) will inherit this contract.
final class AgentExecutorTests: XCTestCase {

    // MARK: - A minimal in-memory executor for shape / wiring tests

    /// Test double that ignores the request, returns a pre-canned result.
    /// Also records cancel() invocations to verify the fire-and-forget contract.
    final class MockAgentExecutor: AgentExecutor {
        var lastRequest: AgentExecutionRequest?
        var cancelCount = 0
        let fixedResult: AgentExecutionResult
        let throwingLaunchError: Error?

        init(
            result: AgentExecutionResult = .init(
                tool: .claude,
                rawOutput: "ok",
                stderrOutput: "",
                exitCode: 0,
                timedOut: false,
                sessionId: "mock-session",
                duration: 0.01
            ),
            throwingLaunchError: Error? = nil
        ) {
            self.fixedResult = result
            self.throwingLaunchError = throwingLaunchError
        }

        func execute(request: AgentExecutionRequest) throws -> AgentExecutionResult {
            lastRequest = request
            if let err = throwingLaunchError { throw err }
            return fixedResult
        }

        func cancel() {
            cancelCount += 1
        }
    }

    // MARK: - Request

    func testRequest_preservesAllFields() {
        let req = AgentExecutionRequest(
            tool: .codex,
            prompt: "hello",
            resumeSessionId: "prev-id",
            timeout: 60,
            metadata: ["token_budget": "1000"]
        )
        XCTAssertEqual(req.tool, .codex)
        XCTAssertEqual(req.prompt, "hello")
        XCTAssertEqual(req.resumeSessionId, "prev-id")
        XCTAssertEqual(req.timeout, 60)
        XCTAssertEqual(req.metadata["token_budget"], "1000")
    }

    func testRequest_resumeIdDefaultsNil_metadataEmpty() {
        let req = AgentExecutionRequest(tool: .gemini, prompt: "p", timeout: 10)
        XCTAssertNil(req.resumeSessionId)
        XCTAssertEqual(req.metadata, [:])
    }

    // MARK: - Result

    func testResult_sessionIdFirstClass_notInMetadata() {
        let r = AgentExecutionResult(
            tool: .claude,
            rawOutput: "o",
            stderrOutput: "",
            exitCode: 0,
            timedOut: false,
            sessionId: "explicit-id",
            duration: 0.5
        )
        // sessionId is a named field — not a magic metadata key
        XCTAssertEqual(r.sessionId, "explicit-id")
        XCTAssertEqual(r.metadata, [:])
    }

    func testResult_timedOutSurfacedOnResultNotAsException() {
        // Protocol contract (DI12): timeout is a normal result, not a throw.
        let r = AgentExecutionResult(
            tool: .claude,
            rawOutput: "partial",
            stderrOutput: "[killed: per-command timeout exceeded]",
            exitCode: 15,
            timedOut: true,
            sessionId: nil,
            duration: 60
        )
        XCTAssertTrue(r.timedOut)
        XCTAssertEqual(r.exitCode, 15)
    }

    // MARK: - Mock executor contract

    func testMockExecute_receivesRequestVerbatim() throws {
        let exec = MockAgentExecutor()
        let req = AgentExecutionRequest(tool: .claude, prompt: "hi", timeout: 10)
        _ = try exec.execute(request: req)
        XCTAssertEqual(exec.lastRequest, req)
    }

    func testMockCancel_incrementsCounter_evenBeforeExecute() {
        let exec = MockAgentExecutor()
        exec.cancel()
        exec.cancel()
        XCTAssertEqual(exec.cancelCount, 2)
    }

    func testMockExecute_throwsLaunchError() {
        struct BoomError: Error {}
        let exec = MockAgentExecutor(throwingLaunchError: BoomError())
        XCTAssertThrowsError(try exec.execute(request: .init(
            tool: .claude, prompt: "p", timeout: 10
        )))
    }

    // MARK: - Protocol polymorphism smoke

    func testProtocolCanBeUsedPolymorphically() throws {
        let exec: AgentExecutor = MockAgentExecutor()
        let r = try exec.execute(request: .init(tool: .claude, prompt: "p", timeout: 5))
        XCTAssertEqual(r.rawOutput, "ok")
        XCTAssertEqual(r.sessionId, "mock-session")
    }
}
