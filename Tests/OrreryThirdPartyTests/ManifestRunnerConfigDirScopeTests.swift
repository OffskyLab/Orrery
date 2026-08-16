import Testing
import Foundation
@testable import OrreryThirdParty
@testable import OrreryCore

/// `resolveClaudeDir` prefers the account dir that `orrery use` exports as
/// `CLAUDE_CONFIG_DIR`. That preference must still respect the injected
/// `EnvironmentStore`: a `CLAUDE_CONFIG_DIR` pointing somewhere else is not
/// this store's account and must be ignored.
///
/// Before this was enforced, running `swift test` in a shell with orrery's
/// integration loaded made every ManifestRunner test install into the
/// developer's real `~/.orrery` account dir — copying files, writing lock
/// files, and patching their real `settings.json`.
@Suite("ManifestRunner CLAUDE_CONFIG_DIR scoping")
struct ManifestRunnerConfigDirScopeTests {

    private let storeHome = URL(fileURLWithPath: "/tmp/orrery-test-home")

    private func resolve(_ configDir: String?,
                         home: URL? = nil,
                         hasMetadata: Bool = true) -> URL? {
        ManifestRunner.activeAccountDir(
            configDir: configDir,
            storeHome: home ?? storeHome,
            fileExists: { _ in hasMetadata })
    }

    @Test("an account dir inside the store's home is used")
    func insideStoreHome() {
        let dir = "/tmp/orrery-test-home/accounts/claude/acct-1"
        #expect(resolve(dir)?.path == dir)
    }

    @Test("an account dir outside the store's home is ignored")
    func outsideStoreHome() {
        // The real-world case: tests inject a temp home, but the developer's
        // shell exports CLAUDE_CONFIG_DIR pointing at ~/.orrery.
        #expect(resolve("/Users/someone/.orrery/accounts/claude/real-uuid") == nil)
    }

    @Test("a sibling path that merely shares a prefix is not treated as inside")
    func siblingPrefixIsNotInside() {
        // "/tmp/orrery-test-home-other" starts with the home string but is a
        // different directory — a naive hasPrefix check would accept it.
        #expect(resolve("/tmp/orrery-test-home-other/accounts/claude/acct") == nil)
    }

    @Test("the store home itself is accepted")
    func storeHomeItself() {
        #expect(resolve(storeHome.path)?.path == storeHome.path)
    }

    @Test("a dir with no metadata.json is ignored even when inside the home")
    func missingMetadata() {
        #expect(resolve("/tmp/orrery-test-home/accounts/claude/acct-1",
                        hasMetadata: false) == nil)
    }

    @Test("nil CLAUDE_CONFIG_DIR yields nil")
    func nilConfigDir() {
        #expect(resolve(nil) == nil)
    }

    @Test("empty CLAUDE_CONFIG_DIR yields nil")
    func emptyConfigDir() {
        #expect(resolve("") == nil)
    }

    @Test("relative path components are resolved before the containment check")
    func traversalIsNormalized() {
        // A path that escapes the home via .. must not be accepted.
        #expect(resolve("/tmp/orrery-test-home/../elsewhere/accounts/claude/a") == nil)
    }
}
