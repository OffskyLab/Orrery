import Testing
import Foundation
@testable import OrreryCore

#if os(macOS)
@Suite("TokenRefreshDaemonInstaller.plistXML (pure, no launchctl/disk I/O)")
struct TokenRefreshDaemonInstallerTests {
    @Test("generates a well-formed plist with the expected keys")
    func generatesExpectedKeys() throws {
        let logURL = URL(fileURLWithPath: "/Users/test/.orrery/logs/token-refresh.log")
        let xml = TokenRefreshDaemonInstaller.plistXML(
            binaryPath: "/Users/test/.orrery/bin/Orrery",
            intervalSeconds: 900,
            logURL: logURL
        )

        let data = try #require(xml.data(using: .utf8))
        let obj = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        #expect(obj["Label"] as? String == TokenRefreshDaemonInstaller.label)
        #expect(obj["ProgramArguments"] as? [String] == ["/Users/test/.orrery/bin/Orrery"])
        #expect(obj["StartInterval"] as? Int == 900)
        #expect(obj["RunAtLoad"] as? Bool == true)
        #expect(obj["StandardOutPath"] as? String == logURL.path)
        #expect(obj["StandardErrorPath"] as? String == logURL.path)
    }

    @Test("is deterministic — same inputs produce identical content")
    func isDeterministic() {
        let logURL = URL(fileURLWithPath: "/Users/test/.orrery/logs/token-refresh.log")
        let a = TokenRefreshDaemonInstaller.plistXML(
            binaryPath: "/path/to/orrery-agent", intervalSeconds: 900, logURL: logURL
        )
        let b = TokenRefreshDaemonInstaller.plistXML(
            binaryPath: "/path/to/orrery-agent", intervalSeconds: 900, logURL: logURL
        )
        #expect(a == b)
    }

    @Test("changes when the binary path changes — this is what drives self-heal on upgrade")
    func changesWithBinaryPath() {
        let logURL = URL(fileURLWithPath: "/Users/test/.orrery/logs/token-refresh.log")
        let a = TokenRefreshDaemonInstaller.plistXML(
            binaryPath: "/path/a/orrery-agent", intervalSeconds: 900, logURL: logURL
        )
        let b = TokenRefreshDaemonInstaller.plistXML(
            binaryPath: "/path/b/orrery-agent", intervalSeconds: 900, logURL: logURL
        )
        #expect(a != b)
    }
}

@Suite("TokenRefreshDaemonInstaller.ensureFriendlyAgentSymlink (isolated $ORRERY_HOME, no launchctl)")
struct TokenRefreshDaemonInstallerSymlinkTests {
    @Test("creates a symlink pointing at the real agent binary and returns its path")
    func createsSymlink() throws {
        try withIsolatedHome {
            let realPath = "/usr/local/bin/orrery-agent"
            let result = TokenRefreshDaemonInstaller.ensureFriendlyAgentSymlink(pointingTo: realPath)

            #expect(result == TokenRefreshDaemonInstaller.friendlyAgentSymlinkURL.path)
            let target = try FileManager.default.destinationOfSymbolicLink(
                atPath: TokenRefreshDaemonInstaller.friendlyAgentSymlinkURL.path
            )
            #expect(target == realPath)
        }
    }

    @Test("is idempotent when the target hasn't changed")
    func idempotentWhenUnchanged() throws {
        try withIsolatedHome {
            let realPath = "/usr/local/bin/orrery-agent"
            _ = TokenRefreshDaemonInstaller.ensureFriendlyAgentSymlink(pointingTo: realPath)
            let result = TokenRefreshDaemonInstaller.ensureFriendlyAgentSymlink(pointingTo: realPath)

            #expect(result == TokenRefreshDaemonInstaller.friendlyAgentSymlinkURL.path)
            let target = try FileManager.default.destinationOfSymbolicLink(
                atPath: TokenRefreshDaemonInstaller.friendlyAgentSymlinkURL.path
            )
            #expect(target == realPath)
        }
    }

    @Test("repoints the symlink when the real binary path changes (e.g. after an upgrade)")
    func repointsOnBinaryPathChange() throws {
        try withIsolatedHome {
            _ = TokenRefreshDaemonInstaller.ensureFriendlyAgentSymlink(pointingTo: "/usr/local/bin/orrery-agent")
            let newPath = "/opt/homebrew/bin/orrery-agent"
            let result = TokenRefreshDaemonInstaller.ensureFriendlyAgentSymlink(pointingTo: newPath)

            #expect(result == TokenRefreshDaemonInstaller.friendlyAgentSymlinkURL.path)
            let target = try FileManager.default.destinationOfSymbolicLink(
                atPath: TokenRefreshDaemonInstaller.friendlyAgentSymlinkURL.path
            )
            #expect(target == newPath)
        }
    }

    @Test("removeStaleLegacySymlinks cleans up the old 'Orrery Inc.' symlink briefly shipped in v3.2.0")
    func removesStaleLegacySymlink() throws {
        try withIsolatedHome {
            let legacyURL = orreryHomeURL().appendingPathComponent("bin/Orrery Inc.")
            try FileManager.default.createDirectory(
                at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                atPath: legacyURL.path, withDestinationPath: "/usr/local/bin/orrery-agent"
            )
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: legacyURL.path)) != nil)

            TokenRefreshDaemonInstaller.removeStaleLegacySymlinks()

            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: legacyURL.path)) == nil)
        }
    }
}
#endif
