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
#endif
