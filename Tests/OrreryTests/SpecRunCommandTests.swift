import XCTest
@testable import OrreryCore

final class SpecRunCommandTests: XCTestCase {

    // MARK: - Helpers

    private func writeFixture(_ contents: String, name: String = UUID().uuidString) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("specrun-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).md")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func run(
        specPath: String,
        execute: Bool = false,
        strictPolicy: Bool = false,
        review: Bool = false,
        resumeSessionId: String? = nil
    ) throws -> SpecRunResult {
        try SpecVerifyRunner.run(
            specPath: specPath,
            tool: nil,
            environment: nil,
            store: EnvironmentStore.default,
            execute: execute,
            strictPolicy: strictPolicy,
            perCommandTimeout: 10,
            overallTimeout: 30,
            review: review,
            resumeSessionId: resumeSessionId
        )
    }

    // MARK: - dry-run default

    func testDryRun_allCommandsSkipped() throws {
        let path = try writeFixture("""
        ## 驗收標準

        - [ ] first
        - [ ] second

        ```bash
        swift build
        echo ok
        ```
        """)
        let result = try run(specPath: path)
        XCTAssertEqual(result.phase, "verify")
        XCTAssertNil(result.sessionId)
        XCTAssertEqual(result.verification.checklist.count, 2)
        XCTAssertTrue(result.verification.checklist.allSatisfy { $0.status == .skipped })
        XCTAssertEqual(result.verification.testResults.count, 2)
        XCTAssertTrue(result.verification.testResults.allSatisfy {
            $0.status == .skipped && $0.skippedReason == "dry-run"
        })
        XCTAssertNil(result.review)
        XCTAssertNil(result.error)
    }

    // MARK: - full JSON shape stability

    func testJSONShapeContainsAllTopLevelKeys() throws {
        let path = try writeFixture("""
        ## 驗收標準

        - [ ] a

        ```bash
        swift build
        ```
        """)
        let result = try run(specPath: path)
        let json = try result.toJSONString()
        let data = json.data(using: .utf8)!
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed)
        let keys = Set(parsed!.keys)
        XCTAssertTrue(keys.contains("session_id"))
        XCTAssertTrue(keys.contains("phase"))
        XCTAssertTrue(keys.contains("completed_steps"))
        XCTAssertTrue(keys.contains("verification"))
        XCTAssertTrue(keys.contains("summary_markdown"))
        XCTAssertTrue(keys.contains("stderr"))
        XCTAssertTrue(keys.contains("diff_summary"))
    }

    func testErrorShellHasFullSchema() throws {
        let result = SpecRunResult.errorShell(phase: "verify", error: "test error")
        let json = try result.toJSONString()
        let data = json.data(using: .utf8)!
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!["phase"] as? String, "verify")
        XCTAssertEqual(parsed!["error"] as? String, "test error")
        XCTAssertNotNil(parsed!["verification"])
        XCTAssertNotNil(parsed!["completed_steps"])
    }

    // MARK: - missing acceptance section

    func testMissingAcceptanceSection_throws() throws {
        let path = try writeFixture("""
        # Title

        No acceptance here.
        """)
        XCTAssertThrowsError(try run(specPath: path))
    }

    // MARK: - spec file not found

    func testSpecNotFound_throws() {
        XCTAssertThrowsError(try run(specPath: "/nonexistent/\(UUID().uuidString).md"))
    }

    // MARK: - resume session id is ignored (fresh session, noted in stderr)

    func testResumeSessionId_ignoredAndNotedInStderr() throws {
        let path = try writeFixture("""
        ## 驗收標準

        - [ ] x

        ```bash
        swift build
        ```
        """)
        let result = try run(specPath: path, resumeSessionId: "ignored-id-123")
        XCTAssertNil(result.sessionId)
        XCTAssertTrue(result.stderr.contains("ignored-id-123"),
                      "stderr should mention the ignored id, got: \(result.stderr)")
    }

    // MARK: - policy_blocked does not cause fail; strict_policy makes it fail

    func testPolicyBlocked_inExecuteMode_statusRecorded() throws {
        let path = try writeFixture("""
        ## 驗收標準

        ```bash
        git push origin main
        ```
        """)
        let result = try run(specPath: path, execute: true)
        XCTAssertEqual(result.verification.testResults.count, 1)
        XCTAssertEqual(result.verification.testResults[0].status, .policyBlocked)
        XCTAssertNotNil(result.verification.testResults[0].skippedReason)
        XCTAssertTrue(result.verification.testResults[0].skippedReason!.hasPrefix("blocklist:"))
    }

    // MARK: - review three-state

    func testReviewNil_whenReviewFalse() throws {
        let path = try writeFixture("""
        ## 驗收標準

        - [ ] a
        """)
        let result = try run(specPath: path, review: false)
        XCTAssertNil(result.review)
    }

    func testReviewAdvisoryOnly_whenVerifyHasFail() throws {
        let path = try writeFixture("""
        ## 驗收標準

        ```bash
        swift build --does-not-exist-flag-to-force-failure
        ```
        """)
        // execute=true to actually run the command (so it fails)
        let result = try run(specPath: path, execute: true, review: true)
        XCTAssertNotNil(result.review)
        XCTAssertEqual(result.review?.verdict, .advisoryOnly)
        XCTAssertTrue(result.review?.reasoning.contains("verify did not fully pass") ?? false)
    }

    // MARK: - summary_markdown not empty

    func testSummaryMarkdownIncludesCounts() throws {
        let path = try writeFixture("""
        ## 驗收標準

        - [ ] one
        - [ ] two

        ```bash
        echo hi
        ```
        """)
        let result = try run(specPath: path)
        XCTAssertTrue(result.summaryMarkdown.contains("Verify Summary"))
        XCTAssertTrue(result.summaryMarkdown.contains("Checklist items: 2"))
        XCTAssertTrue(result.summaryMarkdown.contains("Commands: 1"))
    }

    // MARK: - completed_steps reflects mode

    func testCompletedSteps_dryRun() throws {
        let path = try writeFixture("""
        ## 驗收標準

        ```bash
        swift build
        ```
        """)
        let result = try run(specPath: path, execute: false)
        XCTAssertEqual(result.completedSteps, ["parsed", "dry-run"])
    }

    // MARK: - JSON uses snake_case for multi-word fields

    func testJSONUsesSnakeCase() throws {
        let path = try writeFixture("""
        ## 驗收標準

        - [ ] a

        ```bash
        swift build
        ```
        """)
        let result = try run(specPath: path)
        let json = try result.toJSONString()
        XCTAssertTrue(json.contains("\"session_id\""))
        XCTAssertTrue(json.contains("\"completed_steps\""))
        XCTAssertTrue(json.contains("\"summary_markdown\""))
        XCTAssertTrue(json.contains("\"diff_summary\""))
        XCTAssertFalse(json.contains("\"sessionId\""))
        XCTAssertFalse(json.contains("\"completedSteps\""))
    }
}
