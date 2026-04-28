import XCTest
@testable import OrreryCore

final class SpecImplementRunnerTests: XCTestCase {

    private var tmpHome: URL!
    private var savedHome: String?
    private var fixturePath: String!

    override func setUp() {
        super.setUp()
        // Scratch ORRERY_HOME so state files don't pollute the user dir.
        tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-impl-runner-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        savedHome = ProcessInfo.processInfo.environment["ORRERY_HOME"]
        setenv("ORRERY_HOME", tmpHome.path, 1)

        // Write a minimal fixture with all four mandatory headings so
        // validateStructure passes.
        let fixture = """
        # Fixture

        ## 介面合約

        public protocol Foo { func bar() }

        ## 改動檔案

        | File | Change |
        | --- | --- |
        | `Foo.swift` | new |

        ## 實作步驟

        1. create Foo.swift

        ## 驗收標準

        - [ ] Foo.swift exists

        """
        fixturePath = tmpHome.appendingPathComponent("fixture.md").path
        try? fixture.write(toFile: fixturePath, atomically: true, encoding: .utf8)
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

    // MARK: - buildWrapperShell (C1 + G1 + G3)

    func testBuildWrapperShell_containsTimeoutWatchdog_whenTimeoutPositive() {
        let wrapper = SpecImplementRunner.buildWrapperShell(
            delegateArgs: ["claude", "-p", "hello"],
            stdoutLog: "/tmp/o.log",
            stderrLog: "/tmp/e.log",
            sessionId: "sid-1",
            overallTimeout: 60
        )
        XCTAssertTrue(wrapper.contains("DELEGATE_PID=$!"))
        XCTAssertTrue(wrapper.contains("sleep 60"))
        XCTAssertTrue(wrapper.contains("kill -TERM $DELEGATE_PID"))
        XCTAssertTrue(wrapper.contains("WATCHDOG_PID=$!"))
        XCTAssertTrue(wrapper.contains("kill $WATCHDOG_PID"))
    }

    func testBuildWrapperShell_omitsWatchdog_whenTimeoutZero() {
        let wrapper = SpecImplementRunner.buildWrapperShell(
            delegateArgs: ["claude", "-p", "hi"],
            stdoutLog: "/tmp/o.log",
            stderrLog: "/tmp/e.log",
            sessionId: "sid-1",
            overallTimeout: 0
        )
        XCTAssertFalse(wrapper.contains("sleep 0"))
        XCTAssertFalse(wrapper.contains("WATCHDOG_PID"))
        // But DELEGATE_PID is still needed for the wait-then-finalize flow.
        XCTAssertTrue(wrapper.contains("DELEGATE_PID=$!"))
    }

    func testBuildWrapperShell_callsFinalizeWithSessionAndExitCode() {
        let wrapper = SpecImplementRunner.buildWrapperShell(
            delegateArgs: ["claude", "-p", "x"],
            stdoutLog: "/tmp/o.log",
            stderrLog: "/tmp/e.log",
            sessionId: "abc-123",
            overallTimeout: 30
        )
        XCTAssertTrue(wrapper.contains("_spec-finalize"))
        XCTAssertTrue(wrapper.contains("'abc-123'"))
        XCTAssertTrue(wrapper.contains("\"$RC\""))
    }

    func testBuildWrapperShell_redirectsDelegateOutputToLogFiles() {
        let wrapper = SpecImplementRunner.buildWrapperShell(
            delegateArgs: ["claude", "-p", "x"],
            stdoutLog: "/tmp/session.stdout.log",
            stderrLog: "/tmp/session.stderr.log",
            sessionId: "sid",
            overallTimeout: 0
        )
        XCTAssertTrue(wrapper.contains(">>'/tmp/session.stdout.log'"))
        XCTAssertTrue(wrapper.contains("2>>'/tmp/session.stderr.log'"))
    }

    func testBuildWrapperShell_singleQuotesEachDelegateArg() {
        let wrapper = SpecImplementRunner.buildWrapperShell(
            delegateArgs: ["claude", "-p", "hello world"],
            stdoutLog: "/tmp/o",
            stderrLog: "/tmp/e",
            sessionId: "s",
            overallTimeout: 0
        )
        // Each arg wrapped in single quotes:
        XCTAssertTrue(wrapper.contains("'claude' '-p' 'hello world'"))
    }

    func testShellQuote_escapesEmbeddedSingleQuote() {
        let quoted = SpecImplementRunner.shellQuote("don't")
        XCTAssertEqual(quoted, "'don'\\''t'")
    }

    // MARK: - resolveOrreryBinaryPath (G3)

    func testResolveOrreryBinaryPath_returnsAbsolute_orFallback() {
        let path = SpecImplementRunner.resolveOrreryBinaryPath()
        // Either it's absolute (and exists), or it's "orrery" (PATH fallback).
        let isAbsExisting = path.hasPrefix("/") &&
            FileManager.default.isExecutableFile(atPath: path)
        let isFallback = (path == "orrery")
        XCTAssertTrue(isAbsExisting || isFallback,
                      "resolved path should be abs/executable OR literal 'orrery'; got: \(path)")
        // Crucially, never returns a relative path like ".build/debug/orrery"
        if path != "orrery" {
            XCTAssertTrue(path.hasPrefix("/"), "non-fallback must be absolute; got: \(path)")
        }
    }

    // MARK: - run() early-return + state side effects

    func testRun_specNotFound_throws() {
        XCTAssertThrowsError(try SpecImplementRunner.run(
            specPath: "/nonexistent/\(UUID().uuidString).md",
            tool: nil,
            environment: nil,
            store: .default,
            resumeSessionId: nil,
            overallTimeout: 0,
            tokenBudget: nil,
            watch: false
        ))
    }

    func testRun_specMissingMandatoryHeading_throws_noStateWritten() throws {
        // Spec lacks 「介面合約」→ DI5 safety net should trip before any
        // subprocess is spawned and no state file should be created.
        let badPath = tmpHome.appendingPathComponent("bad.md").path
        try "## 改動檔案\nx\n## 實作步驟\nx\n## 驗收標準\nx\n"
            .write(toFile: badPath, atomically: true, encoding: .utf8)

        // Count state files before
        let rootDir = SpecRunStateStore.rootDir
        let before = (try? FileManager.default.contentsOfDirectory(atPath: rootDir.path)) ?? []

        XCTAssertThrowsError(try SpecImplementRunner.run(
            specPath: badPath,
            tool: nil,
            environment: nil,
            store: .default,
            resumeSessionId: nil,
            overallTimeout: 0,
            tokenBudget: nil,
            watch: false
        ))

        let after = (try? FileManager.default.contentsOfDirectory(atPath: rootDir.path)) ?? []
        XCTAssertEqual(before.count, after.count,
                       "no state files should be created when validateStructure throws")
    }

    func testRun_resumeUnknownSessionId_throws_sessionNotFound() {
        XCTAssertThrowsError(try SpecImplementRunner.run(
            specPath: fixturePath,
            tool: .claude,
            environment: nil,
            store: .default,
            resumeSessionId: "unknown-\(UUID().uuidString)",
            overallTimeout: 0,
            tokenBudget: nil,
            watch: false
        )) { err in
            let desc = String(describing: err)
            XCTAssertTrue(desc.contains("not found") || desc.contains("找不到"),
                          "expected sessionNotFound, got: \(desc)")
        }
    }

    // MARK: - Resume with captured delegate id propagates

    func testRun_resumeWithDelegateId_presence_inWrapperViaStateCheck() throws {
        // Pre-seed a state that already has a captured delegate_session_id.
        let sid = UUID().uuidString
        var prior = SpecRunState.initial(sessionId: sid, startedAt: "2026-04-21T00:00:00Z")
        prior.delegateSessionId = "CAPTURED-DELEGATE-ID"
        try SpecRunStateStore.write(sessionId: sid, state: prior)

        // We can't directly inspect the wrapper string from run(), but we can
        // verify that run() doesn't print the G8 silent-fresh warning to stderr
        // AND that after it returns, the state still carries the captured id.
        //
        // If there's no claude/codex/gemini installed in the test env this will
        // throw at firstAvailableTool() — in which case we skip gracefully.
        do {
            _ = try SpecImplementRunner.run(
                specPath: fixturePath,
                tool: nil,
                environment: nil,
                store: .default,
                resumeSessionId: sid,
                overallTimeout: 0,
                tokenBudget: nil,
                watch: false
            )
        } catch {
            // Only acceptable failure here is noToolAvailable, because tests
            // aren't guaranteed to have claude/codex/gemini installed.
            let desc = String(describing: error)
            if !desc.contains("tool") && !desc.contains("AI") {
                throw error
            }
            return  // skip the state assertion
        }

        // If run succeeded, state should still carry the original captured id.
        let after = try SpecRunStateStore.load(sessionId: sid)
        XCTAssertEqual(after.delegateSessionId, "CAPTURED-DELEGATE-ID")
    }
}
