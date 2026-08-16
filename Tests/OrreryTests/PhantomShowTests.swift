import Testing
import Foundation
@testable import OrreryCore

@Suite("PhantomShow")
struct PhantomShowTests {
    private func entry(pid: Int32, account: String?, cwd: String,
                       session: String?) -> PhantomEntry {
        PhantomEntry(
            supervisorPid: pid, supervisorStartedAt: 1.0, tool: "claude",
            tty: "/dev/ttys001", cwd: cwd, workspace: "origin",
            account: account, sessionId: session,
            sessionIdSource: session == nil ? .probe : .hook, updatedAt: 1.0)
    }

    @Test("no live sessions produces no lines at all")
    func emptyIsSilent() {
        #expect(ShowCommand.supervisedSessionLines(entries: []).isEmpty)
    }

    @Test("a live session is rendered with tool, account, cwd and session prefix")
    func rendersEntry() {
        let lines = ShowCommand.supervisedSessionLines(entries: [
            ("10", entry(pid: 10, account: "work", cwd: "/tmp/p",
                         session: "abcdef0123456789")),
        ])
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("claude"))
        #expect(joined.contains("work"))
        #expect(joined.contains("/tmp/p"))
        #expect(joined.contains("abcdef01"))
        #expect(!joined.contains("abcdef0123456789"))  // truncated to 8
    }

    @Test("a session with no account or session id renders placeholders")
    func rendersMissingFields() {
        let lines = ShowCommand.supervisedSessionLines(entries: [
            ("10", entry(pid: 10, account: nil, cwd: "/tmp/p", session: nil)),
        ])
        #expect(lines.joined().contains("-"))
    }

    @Test("multiple sessions each get a line")
    func rendersMultiple() {
        let lines = ShowCommand.supervisedSessionLines(entries: [
            ("10", entry(pid: 10, account: "a", cwd: "/x", session: "s1")),
            ("20", entry(pid: 20, account: "b", cwd: "/y", session: "s2")),
        ])
        // One header plus one line per session.
        #expect(lines.count == 3)
    }
}
