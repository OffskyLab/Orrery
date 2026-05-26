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

        let fetched = try GitSource().fetch(
            source: .git(url: "https://github.com/OffskyLab/orrery-claude-statusline",
                         ref: "latest"),
            cacheRoot: cacheRoot,
            packageID: "statusline",
            refOverride: nil,
            forceRefresh: false
        )
        #expect(fetched.sha.count == 40)
        // `latest` should resolve to a tag, so displayLabel is set.
        #expect(fetched.displayLabel != nil)
        #expect(FileManager.default.fileExists(
            atPath: fetched.dir.appendingPathComponent("statusline.js").path))
    }
}
