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
            binaryPath: "/usr/local/bin/orrery-bin",
            intervalSeconds: 900,
            logURL: logURL
        )

        let data = try #require(xml.data(using: .utf8))
        let obj = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        #expect(obj["Label"] as? String == TokenRefreshDaemonInstaller.label)
        #expect(obj["ProgramArguments"] as? [String] == ["/usr/local/bin/orrery-bin", "_refresh-tokens"])
        #expect(obj["StartInterval"] as? Int == 900)
        #expect(obj["RunAtLoad"] as? Bool == true)
        #expect(obj["StandardOutPath"] as? String == logURL.path)
        #expect(obj["StandardErrorPath"] as? String == logURL.path)
    }

    @Test("is deterministic — same inputs produce identical content")
    func isDeterministic() {
        let logURL = URL(fileURLWithPath: "/Users/test/.orrery/logs/token-refresh.log")
        let a = TokenRefreshDaemonInstaller.plistXML(
            binaryPath: "/usr/local/bin/orrery-bin", intervalSeconds: 900, logURL: logURL
        )
        let b = TokenRefreshDaemonInstaller.plistXML(
            binaryPath: "/usr/local/bin/orrery-bin", intervalSeconds: 900, logURL: logURL
        )
        #expect(a == b)
    }

    @Test("changes when the binary path changes — this is what drives self-heal on upgrade")
    func changesWithBinaryPath() {
        let logURL = URL(fileURLWithPath: "/Users/test/.orrery/logs/token-refresh.log")
        let a = TokenRefreshDaemonInstaller.plistXML(
            binaryPath: "/usr/local/bin/orrery-bin", intervalSeconds: 900, logURL: logURL
        )
        let b = TokenRefreshDaemonInstaller.plistXML(
            binaryPath: "/opt/homebrew/bin/orrery-bin", intervalSeconds: 900, logURL: logURL
        )
        #expect(a != b)
    }
}

@Suite("TokenRefreshDaemonInstaller.ensureFriendlyBinarySymlink (isolated $ORRERY_HOME, no launchctl)")
struct TokenRefreshDaemonInstallerSymlinkTests {
    @Test("creates a symlink pointing at the real binary and returns its path")
    func createsSymlink() throws {
        try withIsolatedHome {
            let realPath = "/usr/local/bin/orrery-bin"
            let result = TokenRefreshDaemonInstaller.ensureFriendlyBinarySymlink(pointingTo: realPath)

            #expect(result == TokenRefreshDaemonInstaller.friendlyBinarySymlinkURL.path)
            let target = try FileManager.default.destinationOfSymbolicLink(
                atPath: TokenRefreshDaemonInstaller.friendlyBinarySymlinkURL.path
            )
            #expect(target == realPath)
        }
    }

    @Test("is idempotent when the target hasn't changed")
    func idempotentWhenUnchanged() throws {
        try withIsolatedHome {
            let realPath = "/usr/local/bin/orrery-bin"
            _ = TokenRefreshDaemonInstaller.ensureFriendlyBinarySymlink(pointingTo: realPath)
            let result = TokenRefreshDaemonInstaller.ensureFriendlyBinarySymlink(pointingTo: realPath)

            #expect(result == TokenRefreshDaemonInstaller.friendlyBinarySymlinkURL.path)
            let target = try FileManager.default.destinationOfSymbolicLink(
                atPath: TokenRefreshDaemonInstaller.friendlyBinarySymlinkURL.path
            )
            #expect(target == realPath)
        }
    }

    @Test("repoints the symlink when the real binary path changes (e.g. after an upgrade)")
    func repointsOnBinaryPathChange() throws {
        try withIsolatedHome {
            _ = TokenRefreshDaemonInstaller.ensureFriendlyBinarySymlink(pointingTo: "/usr/local/bin/orrery-bin")
            let newPath = "/opt/homebrew/bin/orrery-bin"
            let result = TokenRefreshDaemonInstaller.ensureFriendlyBinarySymlink(pointingTo: newPath)

            #expect(result == TokenRefreshDaemonInstaller.friendlyBinarySymlinkURL.path)
            let target = try FileManager.default.destinationOfSymbolicLink(
                atPath: TokenRefreshDaemonInstaller.friendlyBinarySymlinkURL.path
            )
            #expect(target == newPath)
        }
    }
}
#endif
