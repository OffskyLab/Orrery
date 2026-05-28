import Foundation
import Testing
@testable import OrreryCore

@Suite("AccountMigration.runV31AccountLayoutIfNeeded")
struct V31AutoMigrationTests {

    @Test("first call migrates all claude accounts and writes the flag")
    func firstCallMigrates() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default

            let acct = Account(tool: .claude, displayName: "alice", email: "alice@x.com")
            try acctStore.save(acct)

            AccountMigration.runV31AccountLayoutIfNeeded(homeURL: orreryHomeURL())

            #expect(ClaudeAccountDirectory.verifySymlinks(
                account: acct, accountStore: acctStore, environmentStore: envStore) == .ok)
            let flag = orreryHomeURL().appendingPathComponent(
                AccountMigration.v31AccountLayoutFlagFileName)
            #expect(FileManager.default.fileExists(atPath: flag.path))
        }
    }

    @Test("second call is a no-op (flag already present)")
    func secondCallNoop() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default

            let acct = Account(tool: .claude, displayName: "alice", email: "alice@x.com")
            try acctStore.save(acct)

            AccountMigration.runV31AccountLayoutIfNeeded(homeURL: orreryHomeURL())

            let identityURL = ClaudeJsonMerge.identityFileURL(
                accountDir: acctStore.accountDir(id: acct.id, tool: .claude))
            let beforeMtime = (try? FileManager.default
                .attributesOfItem(atPath: identityURL.path)[.modificationDate] as? Date) ?? Date()

            Thread.sleep(forTimeInterval: 0.05)

            AccountMigration.runV31AccountLayoutIfNeeded(homeURL: orreryHomeURL())

            let afterMtime = (try? FileManager.default
                .attributesOfItem(atPath: identityURL.path)[.modificationDate] as? Date) ?? Date()
            #expect(beforeMtime == afterMtime,
                "second run should not rewrite identity file (no-op via flag)")
        }
    }

    @Test("never throws — best-effort migration")
    func neverThrows() throws {
        try withIsolatedHome {
            #expect(throws: Never.self) {
                AccountMigration.runV31AccountLayoutIfNeeded(homeURL: orreryHomeURL())
            }
        }
    }
}
