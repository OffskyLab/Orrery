import Testing
import Foundation
@testable import OrreryCore

@Suite("PhantomTargetSelector")
struct PhantomTargetSelectorTests {
    private func entry(pid: Int32, cwd: String, account: String = "a") -> PhantomEntry {
        PhantomEntry(
            supervisorPid: pid, supervisorStartedAt: 1.0, tool: "claude",
            tty: nil, cwd: cwd, workspace: "origin", account: account,
            sessionId: nil, sessionIdSource: .probe, updatedAt: 1.0)
    }

    @Test("an in-chain ORRERY_PHANTOM_ID wins outright")
    func envIdWins() {
        let entries = [("10", entry(pid: 10, cwd: "/a")),
                       ("20", entry(pid: 20, cwd: "/b"))]
        let result = PhantomTargetSelector.select(
            entries: entries, envPhantomId: "20", cwd: "/a", explicit: nil)
        guard case .selected(let id, _) = result else {
            Issue.record("expected .selected, got \(result)"); return
        }
        #expect(id == "20")
    }

    @Test("a stale ORRERY_PHANTOM_ID with no live entry does not select it")
    func staleEnvId() {
        let entries = [("10", entry(pid: 10, cwd: "/a"))]
        let result = PhantomTargetSelector.select(
            entries: entries, envPhantomId: "99", cwd: "/a", explicit: nil)
        guard case .selected(let id, _) = result else {
            Issue.record("expected .selected, got \(result)"); return
        }
        #expect(id == "10")  // falls through to the unique cwd match
    }

    @Test("a unique cwd match is selected")
    func uniqueCwd() {
        let entries = [("10", entry(pid: 10, cwd: "/a")),
                       ("20", entry(pid: 20, cwd: "/b"))]
        let result = PhantomTargetSelector.select(
            entries: entries, envPhantomId: nil, cwd: "/b", explicit: nil)
        guard case .selected(let id, _) = result else {
            Issue.record("expected .selected, got \(result)"); return
        }
        #expect(id == "20")
    }

    @Test("two entries in the same cwd are ambiguous")
    func ambiguousCwd() {
        let entries = [("10", entry(pid: 10, cwd: "/a", account: "work")),
                       ("20", entry(pid: 20, cwd: "/a", account: "personal"))]
        let result = PhantomTargetSelector.select(
            entries: entries, envPhantomId: nil, cwd: "/a", explicit: nil)
        guard case .ambiguous(let candidates) = result else {
            Issue.record("expected .ambiguous, got \(result)"); return
        }
        #expect(candidates.count == 2)
    }

    @Test("no cwd match lists every live entry as a candidate")
    func noCwdMatch() {
        let entries = [("10", entry(pid: 10, cwd: "/a")),
                       ("20", entry(pid: 20, cwd: "/b"))]
        let result = PhantomTargetSelector.select(
            entries: entries, envPhantomId: nil, cwd: "/elsewhere", explicit: nil)
        guard case .ambiguous(let candidates) = result else {
            Issue.record("expected .ambiguous, got \(result)"); return
        }
        #expect(candidates.count == 2)
    }

    @Test("no live entries at all yields .none")
    func nothingLive() {
        let result = PhantomTargetSelector.select(
            entries: [], envPhantomId: nil, cwd: "/a", explicit: nil)
        guard case .none = result else {
            Issue.record("expected .none, got \(result)"); return
        }
    }

    @Test("an explicit id selects directly, overriding cwd")
    func explicitId() {
        let entries = [("10", entry(pid: 10, cwd: "/a")),
                       ("20", entry(pid: 20, cwd: "/b"))]
        let result = PhantomTargetSelector.select(
            entries: entries, envPhantomId: nil, cwd: "/a", explicit: "20")
        guard case .selected(let id, _) = result else {
            Issue.record("expected .selected, got \(result)"); return
        }
        #expect(id == "20")
    }

    @Test("an explicit 1-based index selects from the candidate list")
    func explicitIndex() {
        let entries = [("10", entry(pid: 10, cwd: "/a")),
                       ("20", entry(pid: 20, cwd: "/b"))]
        let result = PhantomTargetSelector.select(
            entries: entries, envPhantomId: nil, cwd: "/nope", explicit: "2")
        guard case .selected(let id, _) = result else {
            Issue.record("expected .selected, got \(result)"); return
        }
        #expect(id == "20")
    }

    @Test("an explicit id that matches nothing yields .none")
    func explicitUnknown() {
        let entries = [("10", entry(pid: 10, cwd: "/a"))]
        let result = PhantomTargetSelector.select(
            entries: entries, envPhantomId: nil, cwd: "/a", explicit: "77")
        guard case .none = result else {
            Issue.record("expected .none, got \(result)"); return
        }
    }

    @Test("an explicit index resolves against the cwd-scoped candidate list, not all entries")
    func explicitIndexScopedToCandidates() {
        // Three live entries; the caller's cwd only matches two of them, so
        // the candidate list the user would see is a strict subset of
        // `entries`. `--session 2` must mean "the 2nd line shown" — id 300 —
        // not `entries[1]`, which is id 200.
        let entries = [("100", entry(pid: 100, cwd: "/a")),
                       ("200", entry(pid: 200, cwd: "/b")),
                       ("300", entry(pid: 300, cwd: "/b"))]
        let result = PhantomTargetSelector.select(
            entries: entries, envPhantomId: nil, cwd: "/b", explicit: "2")
        guard case .selected(let id, _) = result else {
            Issue.record("expected .selected, got \(result)"); return
        }
        #expect(id == "300")
    }
}
