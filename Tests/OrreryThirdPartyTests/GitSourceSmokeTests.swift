import Testing
import Foundation
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("GitSource — network smoke (opt-in)",
       .enabled(if: ProcessInfo.processInfo.environment["ORRERY_NETWORK_TESTS"] == "1"))
struct GitSourceSmokeTests {
    @Test("clones statusline at latest tag and finds statusline.js")
    func realClone() throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-git-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let (dir, sha) = try GitSource().fetch(
            source: .git(url: "https://github.com/OffskyLab/orrery-claude-statusline",
                         ref: "latest"),
            cacheRoot: cacheRoot,
            packageID: "statusline",
            refOverride: nil,
            forceRefresh: false
        )
        #expect(sha.count == 40)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("statusline.js").path))
    }
}
