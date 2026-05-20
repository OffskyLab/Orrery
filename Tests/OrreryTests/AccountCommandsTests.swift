import Testing
import Foundation
@testable import OrreryCore

// MARK: - Isolation helper

/// Each test instance gets a fresh temp directory wired to ORRERY_HOME so that
/// AccountStore.default resolves to an isolated, throwaway location.
/// Pattern mirrors SpecRunStateStoreTests (save/restore ORRERY_HOME via setenv).
private func makeTempHome() throws -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("orrery-acct-cmd-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
}

// MARK: - Suite

@Suite("AccountAddCommand", .serialized)
struct AccountAddTests {
    let tmpDir: URL
    let savedHome: String?

    init() throws {
        tmpDir = try makeTempHome()
        savedHome = ProcessInfo.processInfo.environment["ORRERY_HOME"]
        setenv("ORRERY_HOME", tmpDir.path, 1)
    }

    private func restoreHome() {
        if let saved = savedHome {
            setenv("ORRERY_HOME", saved, 1)
        } else {
            unsetenv("ORRERY_HOME")
        }
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Tests

    @Test("multiple tool flags throws ValidationError")
    func multipleToolFlags() throws {
        defer { restoreHome() }
        // resolveTool is static; test it directly to avoid ArgumentParser init issues.
        #expect(throws: (any Error).self) {
            try AccountAddCommand.resolveTool(claude: true, codex: true, gemini: false)
        }
    }

    @Test("defaults to claude when no tool flag is set")
    func defaultsToClaude() throws {
        defer { restoreHome() }
        let cmd = try AccountAddCommand.parse(["--name", "default-claude-test", "--skip-login"])
        try cmd.run()

        let store = AccountStore(homeURL: tmpDir)
        let accounts = try store.list(tool: .claude)
        #expect(accounts.contains { $0.displayName == "default-claude-test" })
    }

    @Test("--codex flag creates a codex account")
    func codexFlag() throws {
        defer { restoreHome() }
        let cmd = try AccountAddCommand.parse(["--codex", "--name", "codex-test", "--skip-login"])
        try cmd.run()

        let store = AccountStore(homeURL: tmpDir)
        let accounts = try store.list(tool: .codex)
        #expect(accounts.contains { $0.displayName == "codex-test" })
    }

    #if os(macOS)
    @Test("claude account created via add has non-nil keychainItem")
    func claudeAccountHasKeychainItem() throws {
        defer { restoreHome() }
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
    #endif
}
