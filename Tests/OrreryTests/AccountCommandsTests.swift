import Testing
import Foundation
@testable import OrreryCore

// MARK: - Isolation helpers

private func makeTempHome() throws -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("orrery-acct-cmd-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
}

/// Run body with a fresh isolated ORRERY_HOME directory, cleaning up afterwards.
private func withIsolatedHome(_ body: () throws -> Void) throws {
    let tmpDir = try makeTempHome()
    let saved = ProcessInfo.processInfo.environment["ORRERY_HOME"]
    setenv("ORRERY_HOME", tmpDir.path, 1)
    defer {
        if let saved { setenv("ORRERY_HOME", saved, 1) } else { unsetenv("ORRERY_HOME") }
        try? FileManager.default.removeItem(at: tmpDir)
    }
    try body()
}

// MARK: - stdout capture helper

/// Redirect stdout to a temp file, run body, restore stdout, and return output.
/// Uses a file (not a pipe) to avoid blocking when the pipe write end is still open.
/// The caller is responsible for ensuring this does not run concurrently with another
/// call (e.g. by nesting inside a .serialized suite).
func captureStdout(_ body: () throws -> Void) throws -> String {
    let tmpPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("orrery-cap-\(UUID().uuidString).txt").path
    FileManager.default.createFile(atPath: tmpPath, contents: nil)
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    let savedFD = dup(fileno(stdout))
    fflush(stdout)
    let capFD = open(tmpPath, O_WRONLY | O_TRUNC)
    dup2(capFD, fileno(stdout))
    close(capFD)
    defer {
        fflush(stdout)
        dup2(savedFD, fileno(stdout))
        close(savedFD)
    }
    try body()
    fflush(stdout)
    return (try? String(contentsOfFile: tmpPath, encoding: .utf8)) ?? ""
}

// MARK: - All account command tests
//
// Wrapped in a single .serialized parent to prevent concurrent:
//   - ORRERY_HOME setenv/unsetenv races between suites, AND
//   - captureStdout FD-1 redirection races.

@Suite("AccountCommands", .serialized)
struct AccountCommandsAllTests {

    // MARK: AccountAddCommand

    @Suite("AccountAddCommand")
    struct AccountAddTests {
        init() {}

        @Test("multiple tool flags throws ValidationError")
        func multipleToolFlags() throws {
            try withIsolatedHome {
                #expect(throws: (any Error).self) {
                    try AccountAddCommand.resolveTool(claude: true, codex: true, gemini: false)
                }
            }
        }

        @Test("defaults to claude when no tool flag is set")
        func defaultsToClaude() throws {
            try withIsolatedHome {
                let cmd = try AccountAddCommand.parse(["--name", "default-claude-test", "--skip-login"])
                try cmd.run()
                let accounts = try AccountStore.default.list(tool: .claude)
                #expect(accounts.contains { $0.displayName == "default-claude-test" })
            }
        }

        @Test("--codex flag creates a codex account")
        func codexFlag() throws {
            try withIsolatedHome {
                let cmd = try AccountAddCommand.parse(["--codex", "--name", "codex-test", "--skip-login"])
                try cmd.run()
                let accounts = try AccountStore.default.list(tool: .codex)
                #expect(accounts.contains { $0.displayName == "codex-test" })
            }
        }

        #if os(macOS)
        @Test("claude account created via add has non-nil keychainItem")
        func claudeAccountHasKeychainItem() throws {
            try withIsolatedHome {
                let tmpDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORRERY_HOME"]!)
                let cmd = try AccountAddCommand.parse(["--name", "keychain-test", "--skip-login"])
                try cmd.run()
                let store = AccountStore(homeURL: tmpDir)
                let accounts = try store.list(tool: .claude)
                guard let account = accounts.first(where: { $0.displayName == "keychain-test" }) else {
                    Issue.record("Account not found in store")
                    return
                }
                #expect(account.keychainItem != nil)
            }
        }
        #endif
    }

    // MARK: AccountListCommand

    @Suite("AccountListCommand")
    struct AccountListTests {
        init() {}

        @Test("empty store prints listEmpty message")
        func empty() throws {
            try withIsolatedHome {
                let cmd = try AccountListCommand.parse([])
                let output = try captureStdout { try cmd.run() }
                #expect(output.contains("No accounts"))
            }
        }

        @Test("grouped by tool shows all accounts")
        func groupedByTool() throws {
            try withIsolatedHome {
                try AccountStore.default.save(Account(tool: .claude, displayName: "work"))
                try AccountStore.default.save(Account(tool: .codex, displayName: "personal"))
                let cmd = try AccountListCommand.parse([])
                let output = try captureStdout { try cmd.run() }
                #expect(output.contains("work"))
                #expect(output.contains("personal"))
            }
        }

        @Test("--codex filter shows only codex accounts")
        func filterByTool() throws {
            try withIsolatedHome {
                try AccountStore.default.save(Account(tool: .claude, displayName: "should-not-show"))
                try AccountStore.default.save(Account(tool: .codex, displayName: "yes-show"))
                let cmd = try AccountListCommand.parse(["--codex"])
                let output = try captureStdout { try cmd.run() }
                #expect(output.contains("yes-show"))
                #expect(!output.contains("should-not-show"))
            }
        }
    }

    // MARK: AccountShowCommand

    @Suite("AccountShowCommand")
    struct AccountShowTests {
        init() {}

        @Test("unpinned rows show origin and unpinned text")
        func unpinnedRows() throws {
            try withIsolatedHome {
                let cmd = try AccountShowCommand.parse([])
                let output = try captureStdout { try cmd.run() }
                #expect(output.contains("origin"))
                #expect(output.contains("no account pinned"))
            }
        }

        @Test("pinned account shows displayName")
        func pinnedShowsDisplayName() throws {
            try withIsolatedHome {
                let acct = Account(tool: .claude, displayName: "pinned-account")
                try AccountStore.default.save(acct)
                var origin = EnvironmentStore.default.loadOriginConfig()
                origin.accounts["claude"] = acct.id
                try EnvironmentStore.default.saveOriginConfig(origin)
                let cmd = try AccountShowCommand.parse([])
                let output = try captureStdout { try cmd.run() }
                #expect(output.contains("pinned-account"))
            }
        }
    }
}
