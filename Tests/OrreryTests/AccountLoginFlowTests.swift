import Testing
import Foundation
@testable import OrreryCore

// .serialized is required because the tests mutate the global ORRERY_HOME via
// withIsolatedHome and must not run concurrently within the suite.
@Suite("AccountLoginFlow.importFrom", .serialized)
struct AccountLoginFlowTests {

    @Test("imports a codex credential from the staging dir into the pool")
    func importsCodexCredentialIntoPool() throws {
        try withIsolatedHome {
            let store = AccountStore.default
            let account = Account(tool: .codex, displayName: "work")
            try store.save(account)

            let stagingDir = makeStagingDir()
            defer { try? FileManager.default.removeItem(at: stagingDir) }
            let payload = #"{"token":"codex-abc"}"#
            try payload.data(using: .utf8)!
                .write(to: stagingDir.appendingPathComponent("auth.json"))

            try AccountLoginFlow.importFrom(stagingDir: stagingDir, into: account)

            let imported = store.accountDir(id: account.id, tool: .codex)
                .appendingPathComponent("auth.json")
            #expect(FileManager.default.fileExists(atPath: imported.path))
            let content = try String(contentsOf: imported, encoding: .utf8)
            #expect(content == payload)
        }
    }

    @Test("imports a gemini credential from the staging dir into the pool")
    func importsGeminiCredentialIntoPool() throws {
        try withIsolatedHome {
            let store = AccountStore.default
            let account = Account(tool: .gemini, displayName: "personal")
            try store.save(account)

            let stagingDir = makeStagingDir()
            defer { try? FileManager.default.removeItem(at: stagingDir) }
            let payload = #"{"refresh":"gemini-xyz"}"#
            try payload.data(using: .utf8)!
                .write(to: stagingDir.appendingPathComponent("oauth_creds.json"))

            try AccountLoginFlow.importFrom(stagingDir: stagingDir, into: account)

            let imported = store.accountDir(id: account.id, tool: .gemini)
                .appendingPathComponent("oauth_creds.json")
            #expect(FileManager.default.fileExists(atPath: imported.path))
            let content = try String(contentsOf: imported, encoding: .utf8)
            #expect(content == payload)
        }
    }

    @Test("throws when login produced no credential in the staging dir")
    func importThrowsWhenCredentialNotProduced() throws {
        try withIsolatedHome {
            let store = AccountStore.default
            let account = Account(tool: .codex, displayName: "empty")
            try store.save(account)

            // Empty staging dir — login produced nothing.
            let stagingDir = makeStagingDir()
            defer { try? FileManager.default.removeItem(at: stagingDir) }

            #expect(throws: AccountLoginFlow.LoginError.self) {
                try AccountLoginFlow.importFrom(stagingDir: stagingDir, into: account)
            }
        }
    }

    #if os(macOS)
    @Test(
        "imports a claude credential from the staging Keychain service into the account service",
        .disabled(if: ProcessInfo.processInfo.environment["CI"] != nil)
    )
    func importsClaudeCredentialFromKeychain() throws {
        try withIsolatedHome {
            let store = AccountStore.default
            let accountID = UUID().uuidString
            let orreryService = ClaudeKeychain.serviceName(forOrreryAccount: accountID)
            let account = Account(id: accountID, tool: .claude, displayName: "mac",
                                  keychainItem: orreryService)
            try store.save(account)

            let stagingDir = makeStagingDir()
            let stagingService = ClaudeKeychain.service(for: stagingDir.path)
            defer {
                try? FileManager.default.removeItem(at: stagingDir)
                _ = KeychainTestSupport.delete(service: stagingService)
                _ = KeychainTestSupport.delete(service: orreryService)
            }

            // Simulate the tool writing the token to the staging-derived service.
            #expect(ClaudeKeychain.setPassword("claude-token", service: stagingService))

            try AccountLoginFlow.importFrom(stagingDir: stagingDir, into: account)

            #expect(ClaudeKeychain.password(forService: orreryService) == "claude-token")
        }
    }
    #endif

    @Test("importFrom overwrites an existing pooled credential with a new one")
    func importFromOverwritesExistingCredential() throws {
        try withIsolatedHome {
            let store = AccountStore.default
            let account = Account(tool: .codex, displayName: "overwrite-test")
            try store.save(account)

            // First import: {"v":1}
            let stagingDir1 = makeStagingDir()
            defer { try? FileManager.default.removeItem(at: stagingDir1) }
            try #"{\"v\":1}"#.data(using: .utf8)!
                .write(to: stagingDir1.appendingPathComponent("auth.json"))
            try AccountLoginFlow.importFrom(stagingDir: stagingDir1, into: account)

            // Second import: {"v":2}
            let stagingDir2 = makeStagingDir()
            defer { try? FileManager.default.removeItem(at: stagingDir2) }
            let payload2 = #"{"v":2}"#
            try payload2.data(using: .utf8)!
                .write(to: stagingDir2.appendingPathComponent("auth.json"))
            try AccountLoginFlow.importFrom(stagingDir: stagingDir2, into: account)

            let imported = store.accountDir(id: account.id, tool: .codex)
                .appendingPathComponent("auth.json")
            let content = try String(contentsOf: imported, encoding: .utf8)
            #expect(content == payload2)
        }
    }

    // MARK: - Helpers

    private func makeStagingDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-login-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

#if os(macOS)
enum KeychainTestSupport {
    @discardableResult
    static func delete(service: String) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        let account = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        proc.arguments = ["delete-generic-password", "-s", service, "-a", account]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }
}
#endif
