import Testing
import Foundation
@testable import OrreryCore

@Suite("ProcessLiveness")
struct ProcessLivenessTests {
    @Test("start time of the current process is readable and positive")
    func selfStartTime() throws {
        let t = try #require(ProcessLiveness.startTime(pid: getpid()))
        #expect(t > 0)
    }

    @Test("start time is stable across repeated reads")
    func stable() throws {
        let a = try #require(ProcessLiveness.startTime(pid: getpid()))
        let b = try #require(ProcessLiveness.startTime(pid: getpid()))
        #expect(a == b)
    }

    @Test("current process is alive when start time matches")
    func aliveWhenMatching() throws {
        let t = try #require(ProcessLiveness.startTime(pid: getpid()))
        #expect(ProcessLiveness.isAlive(pid: getpid(), startedAt: t))
    }

    @Test("current process is not alive when start time differs (pid recycled)")
    func deadWhenStartTimeDiffers() {
        #expect(!ProcessLiveness.isAlive(pid: getpid(), startedAt: 1.0))
    }

    @Test("start time of a nonexistent pid is nil")
    func missingPid() {
        // -1 is not a valid pid; KERN_PROC_PID lookup for it yields no
        // usable kinfo_proc for our purposes.
        #expect(ProcessLiveness.startTime(pid: -1) == nil)
    }

    @Test("nonexistent pid is not alive")
    func missingPidNotAlive() {
        #expect(!ProcessLiveness.isAlive(pid: -1, startedAt: 1.0))
    }

    @Test("isAlive can be passed directly as PhantomRegistry's liveEntries closure")
    func isAliveMatchesRegistryClosureType() {
        // Task 1's PhantomRegistry.liveEntries takes exactly (Int32, Double) -> Bool.
        // A defaulted extra parameter would silently break this conversion.
        let closure: (Int32, Double) -> Bool = ProcessLiveness.isAlive
        #expect(!closure(-1, 1.0))
    }
}
