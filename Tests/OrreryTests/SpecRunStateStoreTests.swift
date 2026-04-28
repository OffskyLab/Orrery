import XCTest
@testable import OrreryCore

final class SpecRunStateStoreTests: XCTestCase {

    private var tmpHome: URL!
    private var savedHome: String?

    override func setUp() {
        super.setUp()
        // Pin rootDir to a scratch path so tests don't touch the user's
        // real ~/.orrery/spec-runs/. Reuses the same ORRERY_HOME override
        // that EnvironmentStore.default honours.
        tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-state-tests-\(UUID().uuidString)", isDirectory: true)
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

    private func makeState(
        id: String = UUID().uuidString,
        status: String = "running"
    ) -> SpecRunState {
        SpecRunState.initial(sessionId: id, startedAt: "2026-04-21T00:00:00Z")
            .with { $0.status = status }
    }

    // MARK: - Paths

    func testRootDir_usesOrreryHomeOverride() {
        XCTAssertTrue(
            SpecRunStateStore.rootDir.path.hasPrefix(tmpHome.path),
            "rootDir=\(SpecRunStateStore.rootDir.path) should start with tmpHome=\(tmpHome.path)"
        )
        XCTAssertEqual(SpecRunStateStore.rootDir.lastPathComponent, "spec-runs")
    }

    func testSessionPaths_shareCommonStem() {
        let id = "abc-123"
        XCTAssertEqual(SpecRunStateStore.statePath(sessionId: id).lastPathComponent,
                       "abc-123.json")
        XCTAssertEqual(SpecRunStateStore.progressLogPath(sessionId: id).lastPathComponent,
                       "abc-123.progress.jsonl")
        XCTAssertEqual(SpecRunStateStore.stdoutLogPath(sessionId: id).lastPathComponent,
                       "abc-123.stdout.log")
        XCTAssertEqual(SpecRunStateStore.stderrLogPath(sessionId: id).lastPathComponent,
                       "abc-123.stderr.log")
    }

    // MARK: - CRUD round-trip

    func testWrite_createsRootDirAndFile() throws {
        let state = makeState()
        XCTAssertFalse(SpecRunStateStore.exists(sessionId: state.sessionId))
        try SpecRunStateStore.write(sessionId: state.sessionId, state: state)
        XCTAssertTrue(SpecRunStateStore.exists(sessionId: state.sessionId))
    }

    func testWrite_thenLoad_roundTripsAllFields() throws {
        var state = makeState()
        state.delegateSessionId = "delegate-native-abc"
        state.preSessionSnapshot = ["older-1", "older-2"]
        state.completedSteps = ["step-1", "step-2"]
        state.touchedFiles = ["Foo.swift", "Bar.swift"]
        state.diffSummary = "3 files changed"
        state.failedStep = "step-3"
        state.childSessionIds = []
        state.executionGraph = nil
        state.lastError = "compile error"
        try SpecRunStateStore.write(sessionId: state.sessionId, state: state)

        let loaded = try SpecRunStateStore.load(sessionId: state.sessionId)
        XCTAssertEqual(loaded, state)
    }

    func testLoad_missingFile_throws() {
        XCTAssertThrowsError(
            try SpecRunStateStore.load(sessionId: "nonexistent-\(UUID().uuidString)")
        ) { err in
            let desc = String(describing: err)
            XCTAssertTrue(desc.contains("not found") || desc.contains("找不到"),
                          "expected sessionNotFound message, got: \(desc)")
        }
    }

    func testUpdate_mutateChangesAreWritten_andUpdatedAtIsStamped() throws {
        let state = makeState()
        try SpecRunStateStore.write(sessionId: state.sessionId, state: state)

        let original = try SpecRunStateStore.load(sessionId: state.sessionId)
        // Ensure updatedAt changes — add brief sleep is too flaky, rely on ISO
        // formatter granularity; since ISO8601DateFormatter is second-grain,
        // we compare status change instead.
        try SpecRunStateStore.update(sessionId: state.sessionId) { s in
            s.status = "done"
            s.completedAt = "2026-04-21T01:00:00Z"
        }
        let updated = try SpecRunStateStore.load(sessionId: state.sessionId)
        XCTAssertEqual(updated.status, "done")
        XCTAssertEqual(updated.completedAt, "2026-04-21T01:00:00Z")
        // updatedAt should be rewritten to "now"; original.updatedAt was "2026-04-21T00:00:00Z"
        XCTAssertNotEqual(updated.updatedAt, original.updatedAt)
    }

    func testUpdate_missingFile_throws() {
        XCTAssertThrowsError(try SpecRunStateStore.update(
            sessionId: "nonexistent-\(UUID().uuidString)"
        ) { $0.status = "done" })
    }

    // MARK: - JSON shape — snake_case keys + null Optionals

    func testJSON_usesSnakeCaseKeys() throws {
        let state = makeState()
        try SpecRunStateStore.write(sessionId: state.sessionId, state: state)
        let content = try String(
            contentsOf: SpecRunStateStore.statePath(sessionId: state.sessionId),
            encoding: .utf8
        )
        XCTAssertTrue(content.contains("\"session_id\""))
        XCTAssertTrue(content.contains("\"started_at\""))
        XCTAssertTrue(content.contains("\"completed_steps\""))
        XCTAssertTrue(content.contains("\"touched_files\""))
        XCTAssertTrue(content.contains("\"child_session_ids\""))
        XCTAssertTrue(content.contains("\"execution_graph\""))
        XCTAssertTrue(content.contains("\"delegate_session_id\""))
        XCTAssertTrue(content.contains("\"pre_session_snapshot\""))
        XCTAssertFalse(content.contains("\"sessionId\""),
                       "Swift camelCase must not leak into JSON")
    }

    func testJSON_nullOptionalsAppearExplicitly() throws {
        let state = makeState()
        try SpecRunStateStore.write(sessionId: state.sessionId, state: state)
        let content = try String(
            contentsOf: SpecRunStateStore.statePath(sessionId: state.sessionId),
            encoding: .utf8
        )
        // completed_at / diff_summary / blocked_reason / failed_step / execution_graph
        // / last_error / delegate_session_id are all nil in the initial state
        // but must appear as explicit nulls.
        XCTAssertTrue(content.contains("\"completed_at\" : null") ||
                      content.contains("\"completed_at\": null") ||
                      content.contains("\"completed_at\":null"))
        XCTAssertTrue(content.contains("\"delegate_session_id\" : null") ||
                      content.contains("\"delegate_session_id\": null") ||
                      content.contains("\"delegate_session_id\":null"))
        XCTAssertTrue(content.contains("\"execution_graph\" : null") ||
                      content.contains("\"execution_graph\": null") ||
                      content.contains("\"execution_graph\":null"))
    }

    // MARK: - DI3 reserved fields round-trip

    func testDI3ReservedFields_roundTripWithDefaults() throws {
        let state = makeState()
        XCTAssertEqual(state.childSessionIds, [])
        XCTAssertNil(state.executionGraph)
        try SpecRunStateStore.write(sessionId: state.sessionId, state: state)
        let loaded = try SpecRunStateStore.load(sessionId: state.sessionId)
        XCTAssertEqual(loaded.childSessionIds, [])
        XCTAssertNil(loaded.executionGraph)
    }

    // MARK: - Isolation — different session_ids don't collide

    func testMultipleSessions_haveSeparateFiles() throws {
        let a = makeState()
        var b = makeState()
        b.status = "done"
        try SpecRunStateStore.write(sessionId: a.sessionId, state: a)
        try SpecRunStateStore.write(sessionId: b.sessionId, state: b)
        XCTAssertEqual(try SpecRunStateStore.load(sessionId: a.sessionId).status, "running")
        XCTAssertEqual(try SpecRunStateStore.load(sessionId: b.sessionId).status, "done")
    }
}

// MARK: - Test helper

private extension SpecRunState {
    /// Small fluent mutator for test fixtures.
    func with(_ mutate: (inout SpecRunState) -> Void) -> SpecRunState {
        var copy = self
        mutate(&copy)
        return copy
    }
}
