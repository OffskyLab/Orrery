import Foundation
import Testing
@testable import OrreryCore
import OrreryAccountKit

@Suite("AccountMigration.runWorkspaceAccountSymlinksIfNeeded")
struct V31AutoMigrationTests {

    @Test("first call migrates all claude accounts and writes the flag")
    func firstCallMigrates() async throws {
        try await withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default

            let acct = Account(tool: .claude, displayName: "alice", email: "alice@x.com")
            try acctStore.save(acct)

            AccountMigration.runWorkspaceAccountSymlinksIfNeeded(homeURL: orreryHomeURL())

            #expect(try AccountDirectoryRuntime.manager(for: .claude).verifySymlinks(
                account: acct, accountStore: acctStore, environmentStore: envStore) == .ok)
            let flag = orreryHomeURL().appendingPathComponent(
                AccountMigration.workspaceAccountSymlinksFlagFileName)
            #expect(FileManager.default.fileExists(atPath: flag.path))
        }
    }

    @Test("second call is a no-op (flag already present)")
    func secondCallNoop() async throws {
        try await withIsolatedHome {
            let acctStore = AccountStore.default

            let acct = Account(tool: .claude, displayName: "alice", email: "alice@x.com")
            try acctStore.save(acct)

            AccountMigration.runWorkspaceAccountSymlinksIfNeeded(homeURL: orreryHomeURL())

            let identityURL = ClaudeJsonMerge.identityFileURL(
                accountDir: acctStore.accountDir(id: acct.id, tool: .claude))
            let beforeMtime = (try? FileManager.default
                .attributesOfItem(atPath: identityURL.path)[.modificationDate] as? Date) ?? Date()

            // `Task.sleep`, not `Thread.sleep`: this function is async now, and
            // the wait is only here so the mtimes either side are distinguishable.
            try await Task.sleep(for: .milliseconds(50))

            AccountMigration.runWorkspaceAccountSymlinksIfNeeded(homeURL: orreryHomeURL())

            let afterMtime = (try? FileManager.default
                .attributesOfItem(atPath: identityURL.path)[.modificationDate] as? Date) ?? Date()
            #expect(beforeMtime == afterMtime,
                "second run should not rewrite identity file (no-op via flag)")
        }
    }

    @Test("never throws — best-effort migration")
    func neverThrows() async throws {
        try await withIsolatedHome {
            #expect(throws: Never.self) {
                AccountMigration.runWorkspaceAccountSymlinksIfNeeded(homeURL: orreryHomeURL())
            }
        }
    }
}
