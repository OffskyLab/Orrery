import Testing
import Foundation
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("GitSource")
struct GitSourceTests {
    private func tempCacheRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-git-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("40-char hex ref is treated as resolved SHA")
    func recognisesResolvedSHA() throws {
        let cache = try tempCacheRoot()
        defer { try? FileManager.default.removeItem(at: cache) }
        let git = GitSource()
        let sha = String(repeating: "a", count: 40)
        #expect(git.isResolvedSHA(sha))
        #expect(git.isResolvedSHA("main") == false)
        #expect(git.isResolvedSHA("aa") == false)
    }

    @Test("cache key includes resolved SHA")
    func cacheKey() throws {
        let cache = try tempCacheRoot()
        defer { try? FileManager.default.removeItem(at: cache) }
        let git = GitSource()
        let sha = String(repeating: "b", count: 40)
        let dir = git.cacheDir(root: cache, packageID: "cc-statusline", sha: sha)
        #expect(dir.path.hasSuffix("cc-statusline/@\(sha)"))
    }
}
