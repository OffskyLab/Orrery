import XCTest
@testable import OrreryCore

final class SpecRunStateStoreTests: XCTestCase {

    private var tmpHome: URL!
    private var savedHome: String?

    override func setUp() {
        super.setUp()
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
        status: String = "running",
        version: Int = SpecRunStateContract.currentVersion
    ) -> SpecRunState {
        SpecRunState(
            version: version,
            sessionId: id,
            status: status,
            startedAt: "2026-04-21T00:00:00Z",
            updatedAt: "2026-04-21T00:00:00Z"
        )
    }

    private func writeStateFile(_ state: SpecRunState) throws {
        try FileManager.default.createDirectory(
            at: SpecRunStateStore.rootDir,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(state)
        try data.write(to: SpecRunStateStore.statePath(sessionId: state.sessionId))
    }

    func testRootDir_usesOrreryHomeOverride() {
        XCTAssertTrue(
            SpecRunStateStore.rootDir.path.hasPrefix(tmpHome.path),
            "rootDir=\(SpecRunStateStore.rootDir.path) should start with tmpHome=\(tmpHome.path)"
        )
        XCTAssertEqual(SpecRunStateStore.rootDir.lastPathComponent, "spec-runs")
    }

    func testSessionPaths_shareCommonStem() {
        let id = "abc-123"
        XCTAssertEqual(SpecRunStateStore.statePath(sessionId: id).lastPathComponent, "abc-123.json")
        XCTAssertEqual(SpecRunStateStore.progressLogPath(sessionId: id).lastPathComponent, "abc-123.progress.jsonl")
        XCTAssertEqual(SpecRunStateStore.stdoutLogPath(sessionId: id).lastPathComponent, "abc-123.stdout.log")
        XCTAssertEqual(SpecRunStateStore.stderrLogPath(sessionId: id).lastPathComponent, "abc-123.stderr.log")
    }

    func testExists_reflectsStateFilePresence() throws {
        let state = makeState()
        XCTAssertFalse(SpecRunStateStore.exists(sessionId: state.sessionId))
        try writeStateFile(state)
        XCTAssertTrue(SpecRunStateStore.exists(sessionId: state.sessionId))
    }

    func testLoad_roundTripsAllFieldsFromPrewrittenFile() throws {
        var state = makeState(status: "done")
        state.delegateSessionId = "delegate-native-abc"
        state.preSessionSnapshot = ["older-1", "older-2"]
        state.completedSteps = ["step-1", "step-2"]
        state.touchedFiles = ["Foo.swift", "Bar.swift"]
        state.diffSummary = "3 files changed"
        state.failedStep = "step-3"
        state.lastError = "compile error"

        try writeStateFile(state)

        let loaded = try SpecRunStateStore.load(sessionId: state.sessionId)
        XCTAssertEqual(loaded, state)
    }

    func testLoad_missingFile_throws() {
        XCTAssertThrowsError(
            try SpecRunStateStore.load(sessionId: "nonexistent-\(UUID().uuidString)")
        ) { err in
            let desc = String(describing: err)
            XCTAssertTrue(desc.contains("not found") || desc.contains("找不到"))
        }
    }

    func testLoad_legacyFileWithoutVersionDefaultsToOne() throws {
        let sessionId = UUID().uuidString
        try FileManager.default.createDirectory(
            at: SpecRunStateStore.rootDir,
            withIntermediateDirectories: true
        )
        let content = """
        {
          "session_id": "\(sessionId)",
          "delegate_session_id": null,
          "pre_session_snapshot": [],
          "phase": "implement",
          "status": "running",
          "started_at": "2026-04-21T00:00:00Z",
          "updated_at": "2026-04-21T00:00:00Z",
          "completed_at": null,
          "completed_steps": [],
          "touched_files": [],
          "diff_summary": null,
          "blocked_reason": null,
          "failed_step": null,
          "child_session_ids": [],
          "execution_graph": null,
          "last_error": null
        }
        """
        try content.write(
            to: SpecRunStateStore.statePath(sessionId: sessionId),
            atomically: true,
            encoding: .utf8
        )

        let loaded = try SpecRunStateStore.load(sessionId: sessionId)
        XCTAssertEqual(loaded.version, 1)
    }

    func testJSON_usesSnakeCaseKeys() throws {
        let state = makeState()
        try writeStateFile(state)
        let content = try String(
            contentsOf: SpecRunStateStore.statePath(sessionId: state.sessionId),
            encoding: .utf8
        )

        XCTAssertTrue(content.contains("\"version\""))
        XCTAssertTrue(content.contains("\"session_id\""))
        XCTAssertTrue(content.contains("\"started_at\""))
        XCTAssertTrue(content.contains("\"completed_steps\""))
        XCTAssertTrue(content.contains("\"touched_files\""))
        XCTAssertTrue(content.contains("\"child_session_ids\""))
        XCTAssertTrue(content.contains("\"execution_graph\""))
        XCTAssertTrue(content.contains("\"delegate_session_id\""))
        XCTAssertTrue(content.contains("\"pre_session_snapshot\""))
        XCTAssertFalse(content.contains("\"sessionId\""))
    }

    func testJSON_nullOptionalsAppearExplicitly() throws {
        let state = makeState()
        try writeStateFile(state)
        let content = try String(
            contentsOf: SpecRunStateStore.statePath(sessionId: state.sessionId),
            encoding: .utf8
        )

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

    func testMultipleSessions_haveSeparateFiles() throws {
        let a = makeState()
        let b = makeState(status: "done")
        try writeStateFile(a)
        try writeStateFile(b)

        XCTAssertEqual(try SpecRunStateStore.load(sessionId: a.sessionId).status, "running")
        XCTAssertEqual(try SpecRunStateStore.load(sessionId: b.sessionId).status, "done")
    }
}
