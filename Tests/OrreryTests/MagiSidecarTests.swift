import XCTest
@testable import OrreryMagi

final class MagiSidecarTests: XCTestCase {
    /// When ORRERY_MAGI_PATH points nowhere, resolve() returns nil
    /// (no binary found). The lookup must not throw.
    func testResolveReturnsNilWhenNoBinary() throws {
        let originalPath = ProcessInfo.processInfo.environment["ORRERY_MAGI_PATH"]
        let originalHome = ProcessInfo.processInfo.environment["ORRERY_HOME"]
        unsetenv("ORRERY_MAGI_PATH")

        let tmp = NSTemporaryDirectory() + "orrery-sidecar-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        setenv("ORRERY_HOME", tmp, 1)

        defer {
            try? FileManager.default.removeItem(atPath: tmp)
            if let path = originalPath {
                setenv("ORRERY_MAGI_PATH", path, 1)
            } else {
                unsetenv("ORRERY_MAGI_PATH")
            }
            if let home = originalHome {
                setenv("ORRERY_HOME", home, 1)
            } else {
                unsetenv("ORRERY_HOME")
            }
        }

        let whichBinary = Process()
        whichBinary.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichBinary.arguments = ["orrery-magi"]
        whichBinary.standardOutput = FileHandle.nullDevice
        whichBinary.standardError = FileHandle.nullDevice
        try? whichBinary.run()
        whichBinary.waitUntilExit()

        if whichBinary.terminationStatus == 0 {
            throw XCTSkip("orrery-magi present in PATH; cannot test resolve()=nil")
        }

        XCTAssertNil(MagiSidecar.resolve())
    }

    /// resolve() points at the orrery-magi debug build via
    /// ORRERY_MAGI_PATH and successfully parses capabilities.
    /// Skipped if the sibling repo isn't built.
    func testResolveAgainstAdjacentBinaryIfAvailable() throws {
        let candidate = "/Users/abnertsai/JiaBao/grady/orrery-magi/.build/debug/orrery-magi"
        guard FileManager.default.isExecutableFile(atPath: candidate) else {
            throw XCTSkip("adjacent orrery-magi binary not built; run swift build there first")
        }

        let originalPath = ProcessInfo.processInfo.environment["ORRERY_MAGI_PATH"]
        setenv("ORRERY_MAGI_PATH", candidate, 1)

        defer {
            if let path = originalPath {
                setenv("ORRERY_MAGI_PATH", path, 1)
            } else {
                unsetenv("ORRERY_MAGI_PATH")
            }
        }

        let resolved = MagiSidecar.resolve()
        XCTAssertNotNil(resolved)
        if let resolved {
            XCTAssertEqual(resolved.path, candidate)
            XCTAssertFalse(resolved.version.isEmpty)
            XCTAssertNotNil(resolved.mcpSchema)
        }
    }
}
