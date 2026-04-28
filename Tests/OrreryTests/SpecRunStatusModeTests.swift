import XCTest
@testable import OrreryCore

/// Tests for `orrery spec-run --mode status` + `--mode implement` CLI
/// dispatch. Uses the built `.build/debug/orrery` binary as a subprocess
/// so we can assert on real stdout / exit codes without hijacking the
/// test runner's own stdio.
final class SpecRunStatusModeTests: XCTestCase {

    private var tmpHome: URL!

    override func setUp() {
        super.setUp()
        tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-specrun-cli-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpHome)
        super.tearDown()
    }

    // MARK: - Subprocess helper

    /// Locate the `.build/debug/orrery` binary by walking up from CWD until
    /// we find a `Package.swift` that names the `orrery` executable.
    private func orreryBinaryPath() throws -> String {
        // When run via `swift test`, CWD is the repo root.
        let cwd = FileManager.default.currentDirectoryPath
        let candidate = "\(cwd)/.build/debug/orrery"
        guard FileManager.default.isExecutableFile(atPath: candidate) else {
            throw XCTSkip("debug orrery binary not built at \(candidate) — run `swift build` first")
        }
        return candidate
    }

    private struct ProcessResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private func runCLI(_ args: [String]) throws -> ProcessResult {
        let bin = try orreryBinaryPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = args
        // Pin ORRERY_HOME to the per-test scratch dir so state files
        // don't touch the user's real ~/.orrery/.
        var env = ProcessInfo.processInfo.environment
        env["ORRERY_HOME"] = tmpHome.path
        env.removeValue(forKey: "ORRERY_ACTIVE_ENV")
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    private func writeRunningState(sessionId: String = UUID().uuidString) throws -> String {
        // We write the state via direct file I/O here so the subprocess can
        // read it using the same ORRERY_HOME we pass via env.
        let rootDir = tmpHome.appendingPathComponent("spec-runs", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)

        let state = SpecRunState.initial(sessionId: sessionId, startedAt: "2026-04-22T00:00:00Z")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(state)
        try data.write(to: rootDir.appendingPathComponent("\(sessionId).json"))
        return sessionId
    }

    // MARK: - --mode status: happy path

    func testStatus_withExistingSession_returnsStatusResultShape() throws {
        let sid = try writeRunningState()
        let r = try runCLI(["spec-run", "--mode", "status", "--session-id", sid, "/dev/null"])
        XCTAssertEqual(r.exitCode, 0, "stderr=\(r.stderr)")

        let parsed = try JSONSerialization.jsonObject(with: r.stdout.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(parsed["session_id"] as? String, sid)
        XCTAssertEqual(parsed["status"] as? String, "running")
        XCTAssertNotNil(parsed["progress"])
        // result null when running
        XCTAssertTrue(parsed["result"] is NSNull)
    }

    func testStatus_includeLog_returnsLogTail() throws {
        let sid = try writeRunningState()
        let rootDir = tmpHome.appendingPathComponent("spec-runs", isDirectory: true)
        let progressPath = rootDir.appendingPathComponent("\(sid).progress.jsonl").path
        try "{\"ts\":\"2026-04-22T00:01:00Z\",\"step\":\"step-1\",\"event\":\"start\"}\n"
            .write(toFile: progressPath, atomically: true, encoding: .utf8)

        let r = try runCLI([
            "spec-run", "--mode", "status",
            "--session-id", sid, "--include-log",
            "/dev/null"
        ])
        XCTAssertEqual(r.exitCode, 0, "stderr=\(r.stderr)")
        let parsed = try JSONSerialization.jsonObject(with: r.stdout.data(using: .utf8)!) as! [String: Any]
        let logTail = parsed["log_tail"] as? [String] ?? []
        XCTAssertEqual(logTail.count, 1)
        XCTAssertTrue(logTail[0].contains("step-1"))
    }

    // MARK: - --mode status: error paths

    func testStatus_missingSessionId_emitsErrorShell() throws {
        let r = try runCLI(["spec-run", "--mode", "status", "/dev/null"])
        XCTAssertNotEqual(r.exitCode, 0)
        let parsed = try JSONSerialization.jsonObject(with: r.stdout.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(parsed["phase"] as? String, "status")
        let err = (parsed["error"] as? String) ?? ""
        XCTAssertTrue(err.contains("session-id") || err.contains("session-id"),
                      "expected sessionIdRequired, got: \(err)")
    }

    func testStatus_unknownSessionId_emitsErrorShell() throws {
        let r = try runCLI([
            "spec-run", "--mode", "status",
            "--session-id", "nonexistent-\(UUID().uuidString)",
            "/dev/null"
        ])
        XCTAssertNotEqual(r.exitCode, 0)
        let parsed = try JSONSerialization.jsonObject(with: r.stdout.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(parsed["phase"] as? String, "status")
        let err = (parsed["error"] as? String) ?? ""
        XCTAssertTrue(err.contains("not found") || err.contains("找不到"))
    }

    // MARK: - --mode status: terminal state exits

    func testStatus_failedState_exitCodeNonZero() throws {
        let sid = try writeRunningState()
        // Manually mutate the state to failed
        let rootDir = tmpHome.appendingPathComponent("spec-runs", isDirectory: true)
        var state = try JSONDecoder().decode(
            SpecRunState.self,
            from: try Data(contentsOf: rootDir.appendingPathComponent("\(sid).json"))
        )
        state.status = "failed"
        state.lastError = "compile error"
        state.completedAt = "2026-04-22T00:02:00Z"
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        try enc.encode(state).write(to: rootDir.appendingPathComponent("\(sid).json"))

        let r = try runCLI(["spec-run", "--mode", "status", "--session-id", sid, "/dev/null"])
        XCTAssertEqual(r.exitCode, 1)
        let parsed = try JSONSerialization.jsonObject(with: r.stdout.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(parsed["status"] as? String, "failed")
        XCTAssertEqual(parsed["last_error"] as? String, "compile error")
        XCTAssertNotNil(parsed["result"])  // populated for terminal states
    }

    func testStatus_doneState_exitCode0() throws {
        let sid = try writeRunningState()
        let rootDir = tmpHome.appendingPathComponent("spec-runs", isDirectory: true)
        var state = try JSONDecoder().decode(
            SpecRunState.self,
            from: try Data(contentsOf: rootDir.appendingPathComponent("\(sid).json"))
        )
        state.status = "done"
        state.completedAt = "2026-04-22T00:02:00Z"
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        try enc.encode(state).write(to: rootDir.appendingPathComponent("\(sid).json"))

        let r = try runCLI(["spec-run", "--mode", "status", "--session-id", sid, "/dev/null"])
        XCTAssertEqual(r.exitCode, 0)
    }

    // MARK: - --mode implement validation paths

    func testImplement_specNotFound_errorShell() throws {
        let r = try runCLI([
            "spec-run", "--mode", "implement",
            "/nonexistent/\(UUID().uuidString).md"
        ])
        XCTAssertNotEqual(r.exitCode, 0)
        let parsed = try JSONSerialization.jsonObject(with: r.stdout.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(parsed["phase"] as? String, "implement")
        XCTAssertNotNil(parsed["error"])
    }

    // MARK: - Invalid mode + plan/run not implemented

    func testInvalidMode_errorShell() throws {
        let r = try runCLI(["spec-run", "--mode", "nonesuchmode", "/dev/null"])
        XCTAssertNotEqual(r.exitCode, 0)
        let parsed = try JSONSerialization.jsonObject(with: r.stdout.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(parsed["phase"] as? String, "nonesuchmode")
        let err = (parsed["error"] as? String) ?? ""
        XCTAssertTrue(err.contains("Invalid mode") || err.contains("無效"),
                      "unexpected error: \(err)")
    }

    func testPlanAndRun_areStillNotImplemented() throws {
        for mode in ["plan", "run"] {
            let r = try runCLI(["spec-run", "--mode", mode, "/dev/null"])
            XCTAssertNotEqual(r.exitCode, 0, "mode=\(mode)")
            let parsed = try JSONSerialization.jsonObject(with: r.stdout.data(using: .utf8)!) as! [String: Any]
            XCTAssertEqual(parsed["phase"] as? String, mode)
            let err = (parsed["error"] as? String) ?? ""
            XCTAssertTrue(err.contains("not yet implemented") || err.contains("尚未"),
                          "mode=\(mode): unexpected error: \(err)")
        }
    }

    // MARK: - _spec-finalize is hidden

    func testSpecFinalize_isHiddenFromMainHelp() throws {
        let r = try runCLI(["--help"])
        XCTAssertFalse(r.stdout.contains("_spec-finalize"),
                       "hidden subcommand should NOT appear in `orrery --help` output")
    }

    func testSpecFinalize_isStillInvokable() throws {
        let r = try runCLI(["_spec-finalize", "--help"])
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertTrue(r.stdout.contains("session-id"))
        XCTAssertTrue(r.stdout.contains("exit-code"))
    }
}
