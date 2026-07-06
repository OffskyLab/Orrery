import Foundation
import Testing
@testable import OrreryCore

/// Guards against the test-isolation defect where the suite touched the real
/// ~/.claude: `Tool.defaultConfigDir` used `homeDirectoryForCurrentUser` (which
/// ignores $HOME), so origin-takeover code — which symlinks at
/// `tool.defaultConfigDir` — hijacked the developer's real ~/.claude even though
/// `withIsolatedHome` had redirected ORRERY_HOME.
@Suite("test isolation")
struct TestIsolationTests {

    @Test("withIsolatedHome isolates tool.defaultConfigDir from the real home")
    func isolatesDefaultConfigDir() {
        // Captured OUTSIDE isolation: homeDirectoryForCurrentUser ignores $HOME,
        // so this is always the developer's real home.
        let realClaude = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").path

        withIsolatedHome {
            let isolated = Tool.claude.defaultConfigDir.path
            #expect(isolated != realClaude,
                "defaultConfigDir must NOT resolve to the real ~/.claude inside withIsolatedHome")

            let tmpHome = ProcessInfo.processInfo.environment["ORRERY_HOME"] ?? ""
            #expect(!tmpHome.isEmpty && isolated.hasPrefix(tmpHome),
                "defaultConfigDir should resolve under the isolated temp home")
        }
    }
}
