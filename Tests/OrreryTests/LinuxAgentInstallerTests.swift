import Testing
import Foundation
@testable import OrreryCore

// Linux-only: `LinuxAgentInstaller` itself only exists under `#if os(Linux)`
// (see `Sources/OrreryCore/Setup/LinuxAgentInstaller.swift`), so this suite
// can't compile or run on macOS. It covers only the pure unit-content
// generators — no real `systemctl` calls, matching the same "pure function
// only" testing philosophy as `TokenRefreshDaemonInstaller.plistXML`.
#if os(Linux)
@Suite("LinuxAgentInstaller unit-content generators (pure, no systemctl/disk I/O)")
struct LinuxAgentInstallerTests {
    @Test("serviceUnitContent embeds the agent binary path in ExecStart")
    func serviceUnitEmbedsBinaryPath() {
        let content = LinuxAgentInstaller.serviceUnitContent(agentBinaryPath: "/usr/local/bin/orrery-agent")
        #expect(content.contains("ExecStart=/usr/local/bin/orrery-agent"))
        #expect(content.contains("[Service]"))
        #expect(content.contains("Type=oneshot"))
    }

    @Test("timerUnitContent embeds the interval and enables Persistent")
    func timerUnitEmbedsInterval() {
        let content = LinuxAgentInstaller.timerUnitContent(intervalMinutes: 15)
        #expect(content.contains("OnUnitActiveSec=15min"))
        #expect(content.contains("Persistent=true"))
        #expect(content.contains("WantedBy=timers.target"))
    }

    @Test("is deterministic — same inputs produce identical content")
    func isDeterministic() {
        let a = LinuxAgentInstaller.serviceUnitContent(agentBinaryPath: "/x/orrery-agent")
        let b = LinuxAgentInstaller.serviceUnitContent(agentBinaryPath: "/x/orrery-agent")
        #expect(a == b)
    }

    @Test("changes when the binary path changes — this is what drives self-heal on upgrade")
    func changesWithBinaryPath() {
        let a = LinuxAgentInstaller.serviceUnitContent(agentBinaryPath: "/a/orrery-agent")
        let b = LinuxAgentInstaller.serviceUnitContent(agentBinaryPath: "/b/orrery-agent")
        #expect(a != b)
    }
}
#endif
