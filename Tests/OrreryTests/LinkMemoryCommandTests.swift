import Testing
import Foundation
@testable import OrreryCore

@Suite("LinkMemoryCommand")
struct LinkMemoryCommandTests {

    /// Regression test for a real incident: `_link-memory` resolved its
    /// `CLAUDE_CONFIG_DIR` fallback via `FileManager.default.homeDirectoryForCurrentUser`
    /// directly, ignoring `ORRERY_USER_HOME`. The memory *target* it links to was
    /// already correctly isolated via `ORRERY_HOME` (`EnvironmentStore.default`),
    /// but the symlink *location* was not — so while `ORRERY_HOME` pointed at a
    /// sandbox, the command still wrote a symlink into the developer's real
    /// `~/.claude/projects/<cwd>/memory`, pointing at a target inside the
    /// sandbox. Once the sandbox is torn down (as `withIsolatedHome` and any
    /// temp-dir-based test do), that real symlink dangles and every memory
    /// write against it fails with ENOENT — or, if the sandbox outlives the
    /// process, writes silently vanish. Fixed by routing the fallback through
    /// `userHomeURL()`, the same seam `Tool.defaultConfigDir` and
    /// `SetupCommand.rcFile(for:)` already use.
    @Test("does not touch the real Claude config dir when CLAUDE_CONFIG_DIR is unset")
    func doesNotTouchRealHomeWithoutClaudeConfigDir() throws {
        let realProjectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
        let projectKey = FileManager.default.currentDirectoryPath
            .replacingOccurrences(of: "/", with: "-")
        let realMemoryLink = realProjectsDir
            .appendingPathComponent(projectKey)
            .appendingPathComponent("memory")
        let realDestinationBefore = try? FileManager.default.destinationOfSymbolicLink(atPath: realMemoryLink.path)

        try withIsolatedHome {
            try LinkMemoryCommand().run()

            let userHome = ProcessInfo.processInfo.environment["ORRERY_USER_HOME"] ?? ""
            #expect(!userHome.isEmpty)
            let isolatedMemoryLink = URL(fileURLWithPath: userHome)
                .appendingPathComponent(".claude")
                .appendingPathComponent("projects")
                .appendingPathComponent(projectKey)
                .appendingPathComponent("memory")
            let isolatedDestination = try? FileManager.default.destinationOfSymbolicLink(atPath: isolatedMemoryLink.path)
            #expect(isolatedDestination != nil, "expected the memory symlink to be created under the isolated ORRERY_USER_HOME")
            #expect(isolatedDestination?.hasPrefix(userHome) == true,
                    "expected the symlink target to also live inside the isolated sandbox, got \(isolatedDestination ?? "nil")")
        }

        let realDestinationAfter = try? FileManager.default.destinationOfSymbolicLink(atPath: realMemoryLink.path)
        #expect(realDestinationBefore == realDestinationAfter,
                "orrery _link-memory must not create or repoint the real ~/.claude memory symlink while ORRERY_HOME/ORRERY_USER_HOME are isolated")
    }
}
