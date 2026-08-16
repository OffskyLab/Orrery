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
        // Must be truncated to EXACTLY 8 characters — a `contains` check on
        // the 8-char prefix alone would still pass for prefix(9), prefix(10),
        // etc., since those all contain "abcdef01" as a substring. Split on
        // whitespace and require the truncated id to appear as its own
        // field, not merely as a substring of something longer.
        let fields = joined.split(whereSeparator: { $0 == " " || $0 == "\n" })
        #expect(fields.contains("abcdef01"))
        #expect(!fields.contains("abcdef012"))
        #expect(!joined.contains("abcdef0123456789"))
    }

    @Test("a session with no account or session id renders placeholders")
    func rendersMissingFields() {
        let lines = ShowCommand.supervisedSessionLines(entries: [
            ("10", entry(pid: 10, account: nil, cwd: "/tmp/p", session: nil)),
        ])
        // Two placeholders are expected on the entry line: one for the
        // missing account, one for the missing session id. A regression
        // where only one branch renders "-" (the other rendering "" or
        // "nil") must fail this, so count occurrences rather than just
        // checking presence.
        let fields = lines.joined(separator: "\n").split(whereSeparator: { $0 == " " || $0 == "\n" })
        #expect(fields.filter { $0 == "-" }.count == 2)
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
