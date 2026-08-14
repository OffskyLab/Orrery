import Testing
import Foundation
@testable import OrreryCore

@Suite("SetupCommand")
struct SetupCommandTests {

    /// Regression test for a real incident: `rcFile(for:)` used to resolve via
    /// `FileManager.default.homeDirectoryForCurrentUser` directly, ignoring
    /// `ORRERY_USER_HOME` — the override `withIsolatedHome()` sets so tests never
    /// touch the developer's real home. Since `withIsolatedHome` deliberately
    /// doesn't touch real `$HOME` (that breaks Keychain resolution), any test
    /// that called `rcFile(for:)` inside it silently wrote to the developer's
    /// real `~/.zshrc` / `~/.bashrc`. `rcFile(for:)` must honor the same
    /// override `Tool.defaultConfigDir` and `activateFile()` already do.
    @Test("rcFile(for:) honors ORRERY_USER_HOME, does not resolve to the real home")
    func rcFileHonorsUserHomeOverride() throws {
        try withIsolatedHome {
            let userHome = ProcessInfo.processInfo.environment["ORRERY_USER_HOME"] ?? ""
            #expect(!userHome.isEmpty)
            #expect(SetupCommand.rcFile(for: "zsh").path == "\(userHome)/.zshrc")
            #expect(SetupCommand.rcFile(for: "bash").path == "\(userHome)/.bashrc")
        }
    }

    @Test("writes lazy-bootstrap stub when rc is fresh")
    func appendsWhenMissing() throws {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("zshrc-\(UUID().uuidString)")
        try "# existing content\n".write(to: tmpFile, atomically: true, encoding: .utf8)

        SetupCommand.installShellIntegration(to: tmpFile, activatePath: "/tmp/activate.sh")

        let content = try String(contentsOf: tmpFile, encoding: .utf8)
        #expect(content.contains("# orrery shell integration (lazy bootstrap)"))
        #expect(content.contains("orrery() {"))
        #expect(content.contains(#"source "/tmp/activate.sh""#))
        #expect(content.contains("# existing content"))
    }

    @Test("running setup twice leaves exactly one stub")
    func idempotent() throws {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("zshrc-\(UUID().uuidString)")
        try "# existing content\n".write(to: tmpFile, atomically: true, encoding: .utf8)

        SetupCommand.installShellIntegration(to: tmpFile, activatePath: "/tmp/activate.sh")
        SetupCommand.installShellIntegration(to: tmpFile, activatePath: "/tmp/activate.sh")

        let content = try String(contentsOf: tmpFile, encoding: .utf8)
        let stubCount = content.components(separatedBy: "# orrery shell integration (lazy bootstrap)").count - 1
        #expect(stubCount == 1)
    }

    @Test("migrates legacy `source …/activate.sh` line to the stub")
    func migratesLegacySourceLine() throws {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("zshrc-\(UUID().uuidString)")
        let legacy = """
        # existing content

        # orrery shell integration
        source "/old/path/activate.sh"

        export FOO=bar
        """
        try legacy.write(to: tmpFile, atomically: true, encoding: .utf8)

        SetupCommand.installShellIntegration(to: tmpFile, activatePath: "/new/activate.sh")

        let content = try String(contentsOf: tmpFile, encoding: .utf8)
        // Old shape is gone
        #expect(!content.contains(#"source "/old/path/activate.sh""#))
        // New stub is present with the new path
        #expect(content.contains("# orrery shell integration (lazy bootstrap)"))
        #expect(content.contains(#"source "/new/activate.sh""#))
        // Unrelated content is preserved
        #expect(content.contains("# existing content"))
        #expect(content.contains("export FOO=bar"))
    }

    @Test("migrates legacy `eval \"$(orrery setup)\"` line to the stub")
    func migratesLegacyEvalLine() throws {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("zshrc-\(UUID().uuidString)")
        let legacy = #"""
        # existing content
        eval "$(orrery setup)"
        export FOO=bar
        """#
        try legacy.write(to: tmpFile, atomically: true, encoding: .utf8)

        SetupCommand.installShellIntegration(to: tmpFile, activatePath: "/new/activate.sh")

        let content = try String(contentsOf: tmpFile, encoding: .utf8)
        #expect(!content.contains(#"eval "$(orrery setup)""#))
        #expect(content.contains("# orrery shell integration (lazy bootstrap)"))
        #expect(content.contains("export FOO=bar"))
    }
}
