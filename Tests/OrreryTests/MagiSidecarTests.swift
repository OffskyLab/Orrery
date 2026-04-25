import ArgumentParser
import Foundation
import XCTest
@testable import OrreryMagi

final class MagiSidecarTests: XCTestCase {
    private let adjacentBinary = "/Users/abnertsai/JiaBao/grady/orrery-magi/.build/debug/orrery-magi"

    private func makeTempDir(prefix: String = "orrery-sidecar-test") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func withEnvironment<T>(
        _ updates: [String: String?],
        perform body: () throws -> T
    ) throws -> T {
        let originals = Dictionary(uniqueKeysWithValues: updates.keys.map {
            ($0, ProcessInfo.processInfo.environment[$0])
        })

        for (key, value) in updates {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }

        defer {
            for (key, value) in originals {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        return try body()
    }

    private func fixtureTemplateURL() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/OrreryTests/Fixtures/sidecar/fake-sidecar.sh")
    }

    private func makeFixtureBinary(in dir: URL) throws -> String {
        let target = dir.appendingPathComponent("orrery-magi")
        try FileManager.default.copyItem(at: fixtureTemplateURL(), to: target)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: target.path
        )
        return target.path
    }

    private func isExecutableOnPath(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func assertBinaryNotFound(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case MagiSidecarError.binaryNotFound = error else {
            XCTFail("expected binaryNotFound, got \(error)", file: file, line: line)
            return
        }
    }

    private func assertSchemaVersionUnsupported(
        _ error: Error,
        found: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let MagiSidecarError.schemaVersionUnsupported(actualFound, max) = error else {
            XCTFail("expected schemaVersionUnsupported, got \(error)", file: file, line: line)
            return
        }
        XCTAssertEqual(actualFound, found, file: file, line: line)
        XCTAssertEqual(max, MagiSidecar.maxSchemaVersion, file: file, line: line)
    }

    private func assertShimProtocolIncompatible(
        _ error: Error,
        found: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let MagiSidecarError.shimProtocolIncompatible(actualFound, required) = error else {
            XCTFail("expected shimProtocolIncompatible, got \(error)", file: file, line: line)
            return
        }
        XCTAssertEqual(actualFound, found, file: file, line: line)
        XCTAssertEqual(required, MagiSidecar.shimProtocolVersion, file: file, line: line)
    }

    private func assertExitCode(
        _ error: Error,
        expected: Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let exitCode = error as? ExitCode else {
            XCTFail("expected ExitCode(\(expected)), got \(error)", file: file, line: line)
            return
        }
        XCTAssertEqual(exitCode.rawValue, expected, file: file, line: line)
    }

    func testResolveReturnsNilWhenNoBinary() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try withEnvironment([
            "ORRERY_MAGI_STRICT": nil,
            "ORRERY_MAGI_PATH": nil,
            "ORRERY_HOME": tmp.path,
            "PATH": tmp.path
        ]) {
            XCTAssertNil(MagiSidecar.resolve())
        }
    }

    func testStrictModeThrowsWhenBinaryMissing() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try withEnvironment([
            "ORRERY_MAGI_STRICT": "1",
            "ORRERY_MAGI_PATH": nil,
            "ORRERY_HOME": tmp.path,
            "PATH": tmp.path
        ]) {
            XCTAssertThrowsError(try MagiSidecar.resolveOrFallback()) { error in
                self.assertBinaryNotFound(error)
            }
        }
    }

    func testStrictModeAcceptsCompatibleBinary() throws {
        guard FileManager.default.isExecutableFile(atPath: adjacentBinary) else {
            throw XCTSkip("adjacent orrery-magi binary not built; run swift build there first")
        }

        try withEnvironment([
            "ORRERY_MAGI_STRICT": "true",
            "ORRERY_MAGI_PATH": adjacentBinary
        ]) {
            let resolved = try MagiSidecar.resolveStrict()
            XCTAssertEqual(resolved.path, self.adjacentBinary)
            XCTAssertFalse(resolved.version.isEmpty)
            XCTAssertNotNil(resolved.mcpSchema)
        }
    }

    func testStrictModeRejectsIncompatibleSchemaVersion() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fixture = try makeFixtureBinary(in: tmp)

        try withEnvironment([
            "ORRERY_MAGI_STRICT": "1",
            "ORRERY_MAGI_PATH": fixture,
            "ORRERY_TEST_SIDECAR_MODE": "schema99"
        ]) {
            XCTAssertThrowsError(try MagiSidecar.resolveStrict()) { error in
                self.assertSchemaVersionUnsupported(error, found: 99)
            }
        }
    }

    func testStrictModeRejectsIncompatibleShimProtocol() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fixture = try makeFixtureBinary(in: tmp)

        try withEnvironment([
            "ORRERY_MAGI_STRICT": "1",
            "ORRERY_MAGI_PATH": fixture,
            "ORRERY_TEST_SIDECAR_MODE": "shim0"
        ]) {
            XCTAssertThrowsError(try MagiSidecar.resolveStrict()) { error in
                self.assertShimProtocolIncompatible(error, found: 0)
            }
        }
    }

    func testDispatchPropagatesNonZeroExitCode() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fixture = try makeFixtureBinary(in: tmp)
        let binary = MagiSidecar.ResolvedBinary(path: fixture, version: "test", mcpSchema: nil)

        try withEnvironment(["ORRERY_TEST_SIDECAR_MODE": "exit17"]) {
            XCTAssertThrowsError(try MagiSidecar.dispatch(binary, args: [])) { error in
                self.assertExitCode(error, expected: 17)
            }
        }
    }

    func testDispatchSucceedsOnZeroExit() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fixture = try makeFixtureBinary(in: tmp)
        let binary = MagiSidecar.ResolvedBinary(path: fixture, version: "test", mcpSchema: nil)

        try withEnvironment(["ORRERY_TEST_SIDECAR_MODE": "exit0"]) {
            XCTAssertNoThrow(try MagiSidecar.dispatch(binary, args: []))
        }
    }

    func testRunJSONHandlesGrandchildFDInheritance() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fixture = try makeFixtureBinary(in: tmp)

        try withEnvironment(["ORRERY_TEST_SIDECAR_MODE": "grandchild"]) {
            let start = Date()
            let result = MagiSidecar.runJSON(path: fixture, args: [], timeout: 1)
            let elapsed = Date().timeIntervalSince(start)

            XCTAssertLessThan(elapsed, 4, "runJSON should not deadlock on inherited stdout fds")
            switch result {
            case .success(let json):
                XCTAssertNotNil(json)
            case .failure(let error):
                XCTAssertFalse("\(error)".isEmpty)
            }
        }
    }

    func testSidecarPreservesSessionIDBehavior() throws {
        let orreryBinary = "\(FileManager.default.currentDirectoryPath)/.build/debug/orrery"
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["ORRERY_RUN_REAL_MAGI_TESTS"]?.lowercased() != "1",
            "slow real-tool sidecar test; opt in with ORRERY_RUN_REAL_MAGI_TESTS=1"
        )
        try XCTSkipIf(
            !FileManager.default.isExecutableFile(atPath: orreryBinary),
            "debug orrery binary not built at \(orreryBinary) — run `swift build` first"
        )
        try XCTSkipIf(
            !FileManager.default.isExecutableFile(atPath: adjacentBinary),
            "adjacent orrery-magi binary not built; run swift build there first"
        )
        try XCTSkipIf(!isExecutableOnPath("claude"), "claude not installed on PATH")
        try XCTSkipIf(!isExecutableOnPath("codex"), "codex not installed on PATH")
        try XCTSkipIf(!isExecutableOnPath("gemini"), "gemini not installed on PATH")

        let tmpHome = try makeTempDir(prefix: "orrery-magi-e2e")
        defer { try? FileManager.default.removeItem(at: tmpHome) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: orreryBinary)
        process.arguments = ["magi", "--rounds", "1", "trivial test"]
        var env = ProcessInfo.processInfo.environment
        env["ORRERY_HOME"] = tmpHome.path
        env["ORRERY_MAGI_PATH"] = adjacentBinary
        env["ORRERY_MAGI_STRICT"] = "1"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let stderr = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "stderr=\(stderr)")

        let runDir = tmpHome.appendingPathComponent("magi", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: runDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let runFile = try XCTUnwrap(files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).last)
        let data = try Data(contentsOf: runFile)
        let run = try JSONDecoder().decode(MagiRun.self, from: data)

        XCTAssertGreaterThanOrEqual(
            run.sessionMap?.count ?? 0,
            2,
            "expected at least two session ids in sessionMap; stderr=\(stderr)"
        )
    }
}
