import XCTest
@testable import OrreryCore

/// CLI round-trip tests for `orrery spec-run --mode implement`. These
/// spawn the built binary (same pattern as `SpecRunStatusModeTests`) and
/// cover happy-path state creation + the DI5 four-heading safety net at
/// the CLI boundary.
///
/// Most deep behaviour (transport retry, session id identity, shell quoting)
/// is already covered at the unit level by `SpecImplementRunnerTests`; this
/// file focuses on CLI ↔ runner wiring.
final class SpecImplementCommandTests: XCTestCase {

    private var tmpHome: URL!
    private let fixturePath = "Tests/OrreryTests/Fixtures/minimal-implement-spec.md"

    override func setUp() {
        super.setUp()
        tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-impl-cli-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpHome)
        super.tearDown()
    }

    // MARK: - Helpers

    private func orreryBinary() throws -> String {
        let candidate = "\(FileManager.default.currentDirectoryPath)/.build/debug/orrery"
        guard FileManager.default.isExecutableFile(atPath: candidate) else {
            throw XCTSkip("debug orrery not built — run `swift build` first")
        }
        return candidate
    }

    private struct ProcessResult { let stdout: String; let stderr: String; let exit: Int32 }

    private func runCLI(_ args: [String]) throws -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try orreryBinary())
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["ORRERY_HOME"] = tmpHome.path
        // Don't inherit a real ORRERY_ACTIVE_ENV — tests use an isolated HOME
        // and should NOT try to resolve user-facing env names.
        env.removeValue(forKey: "ORRERY_ACTIVE_ENV")
        p.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return ProcessResult(
            stdout: String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            exit: p.terminationStatus
        )
    }

    /// Skip the test if no delegate CLI is installed — the runner calls
    /// `firstAvailableTool()` which throws `noToolAvailable` in that case.
    private func skipIfNoDelegateTool() throws {
        for name in ["claude", "codex", "gemini"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["which", name]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 { return }
        }
        throw XCTSkip("no delegate CLI (claude/codex/gemini) installed; implement cannot spawn")
    }

    // MARK: - DI5 four-heading safety net at CLI boundary

    func testCLI_specMissingInterfaceHeading_fails_withErrorShell_andNoStateFile() throws {
        // Write a bad fixture missing `## 介面合約`
        let bad = tmpHome.appendingPathComponent("bad.md")
        try "## 改動檔案\nx\n## 實作步驟\nx\n## 驗收標準\nx\n"
            .write(to: bad, atomically: true, encoding: .utf8)

        let r = try runCLI(["spec-run", "--mode", "implement", bad.path])
        XCTAssertNotEqual(r.exit, 0)
        let parsed = try JSONSerialization.jsonObject(with: r.stdout.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(parsed["phase"] as? String, "implement")
        let err = (parsed["error"] as? String) ?? ""
        XCTAssertTrue(err.contains("介面合約") || err.contains("Interface Contract"),
                      "expected missingInterfaceContract, got: \(err)")

        // No state file should have been written
        let rootDir = tmpHome.appendingPathComponent("spec-runs", isDirectory: true)
        let jsons = (try? FileManager.default.contentsOfDirectory(atPath: rootDir.path)) ?? []
        XCTAssertTrue(jsons.filter { $0.hasSuffix(".json") }.isEmpty,
                      "no state file should be created when validateStructure throws")
    }

    // MARK: - Happy-path early-return + state file exists

    func testCLI_validSpec_earlyReturnsRunning_andCreatesStateFile() throws {
        try skipIfNoDelegateTool()

        // Use the shipped fixture; set timeout=2 so the delegate subprocess
        // is watchdog-killed quickly (we don't actually wait for it here;
        // we just assert the IMMEDIATE early-return shape).
        let r = try runCLI([
            "spec-run", "--mode", "implement",
            "--timeout", "2",
            fixturePath
        ])
        XCTAssertEqual(r.exit, 0, "stderr=\(r.stderr)")

        let parsed = try JSONSerialization.jsonObject(with: r.stdout.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(parsed["phase"] as? String, "implement")
        XCTAssertEqual(parsed["status"] as? String, "running")
        let sid = parsed["session_id"] as! String
        XCTAssertFalse(sid.isEmpty)

        // State file exists under ORRERY_HOME/spec-runs
        let stateFile = tmpHome
            .appendingPathComponent("spec-runs")
            .appendingPathComponent("\(sid).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateFile.path),
                      "state file missing at \(stateFile.path)")

        // Cleanup: give the wrapper a moment to finalize, then move on.
        // (The tmpHome will be removed in tearDown; any leftover subprocess
        // writing to /tmp/... after that is benign.)
    }

    // MARK: - status reads state right after implement returns

    func testCLI_implementThenStatus_readsConsistentSession() throws {
        try skipIfNoDelegateTool()

        let r1 = try runCLI([
            "spec-run", "--mode", "implement",
            "--timeout", "2",
            fixturePath
        ])
        XCTAssertEqual(r1.exit, 0, "implement stderr=\(r1.stderr)")
        let implParsed = try JSONSerialization.jsonObject(with: r1.stdout.data(using: .utf8)!) as! [String: Any]
        let sid = implParsed["session_id"] as! String

        // Poll once — status reader should find the same session
        let r2 = try runCLI([
            "spec-run", "--mode", "status",
            "--session-id", sid,
            "/dev/null"
        ])
        // exit is 0 if running/done, 1 if failed; either is fine for this shape check
        let statusParsed = try JSONSerialization.jsonObject(with: r2.stdout.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(statusParsed["session_id"] as? String, sid)
        let st = statusParsed["status"] as? String
        XCTAssertTrue(["running", "done", "failed", "aborted"].contains(st ?? ""),
                      "unexpected status=\(String(describing: st))")
    }
}
