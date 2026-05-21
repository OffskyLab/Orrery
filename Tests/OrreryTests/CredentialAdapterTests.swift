import Testing
import Foundation
@testable import OrreryCore

@Suite("FilesystemCredentialAdapter")
struct FilesystemCredentialAdapterTests {
    var tmpDir: URL!
    var accountStore: AccountStore!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-fs-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        accountStore = AccountStore(homeURL: tmpDir)
    }

    @Test("materialize symlinks codex auth.json into target dir")
    func materializeCodex() throws {
        let account = Account(tool: .codex, displayName: "work")
        try accountStore.save(account)

        let accountDir = accountStore.accountDir(id: account.id, tool: .codex)
        let credsURL = accountDir.appendingPathComponent("auth.json")
        try "{\"token\":\"abc\"}".data(using: .utf8)!.write(to: credsURL)

        let targetDir = tmpDir.appendingPathComponent("target-codex")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let adapter = FilesystemCredentialAdapter(tool: .codex)
        try adapter.materialize(account: account, configDir: targetDir.path, accountStore: accountStore)

        let symlinked = targetDir.appendingPathComponent("auth.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: symlinked.path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: symlinked.path)
        #expect(dest == credsURL.path)
    }

    @Test("materialize is idempotent (no-op when symlink already correct)")
    func idempotent() throws {
        let account = Account(tool: .codex, displayName: "work")
        try accountStore.save(account)
        let credsURL = accountStore.accountDir(id: account.id, tool: .codex)
            .appendingPathComponent("auth.json")
        try "{}".data(using: .utf8)!.write(to: credsURL)

        let targetDir = tmpDir.appendingPathComponent("target-codex-idem")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let adapter = FilesystemCredentialAdapter(tool: .codex)
        try adapter.materialize(account: account, configDir: targetDir.path, accountStore: accountStore)
        try adapter.materialize(account: account, configDir: targetDir.path, accountStore: accountStore)
        // must not throw on the second call
    }

    @Test("materialize replaces stale symlink pointing elsewhere")
    func replacesStale() throws {
        let account = Account(tool: .codex, displayName: "new")
        try accountStore.save(account)
        let newCreds = accountStore.accountDir(id: account.id, tool: .codex)
            .appendingPathComponent("auth.json")
        try "{}".data(using: .utf8)!.write(to: newCreds)

        let targetDir = tmpDir.appendingPathComponent("target-codex-stale")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let symlink = targetDir.appendingPathComponent("auth.json")
        let staleTarget = tmpDir.appendingPathComponent("stale.json")
        try "{}".data(using: .utf8)!.write(to: staleTarget)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: staleTarget)

        let adapter = FilesystemCredentialAdapter(tool: .codex)
        try adapter.materialize(account: account, configDir: targetDir.path, accountStore: accountStore)

        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path)
        #expect(dest == newCreds.path)
    }

    @Test("materialize throws when source credential is absent")
    func throwsWhenSourceMissing() throws {
        let account = Account(tool: .codex, displayName: "no-creds")
        try accountStore.save(account)   // metadata only, no auth.json written

        let targetDir = tmpDir.appendingPathComponent("target-missing")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let adapter = FilesystemCredentialAdapter(tool: .codex)
        #expect(throws: FilesystemCredentialAdapter.Error.self) {
            try adapter.materialize(account: account, configDir: targetDir.path, accountStore: accountStore)
        }
        // no dangling symlink left behind
        let target = targetDir.appendingPathComponent("auth.json")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) == nil)
    }

    @Test("materialize replaces a regular file at target")
    func replacesRegularFile() throws {
        let account = Account(tool: .codex, displayName: "rf")
        try accountStore.save(account)
        let creds = accountStore.accountDir(id: account.id, tool: .codex)
            .appendingPathComponent("auth.json")
        try "{}".data(using: .utf8)!.write(to: creds)

        let targetDir = tmpDir.appendingPathComponent("target-regularfile")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        // pre-existing regular file sitting where the symlink should go
        let target = targetDir.appendingPathComponent("auth.json")
        try "old-direct-write".data(using: .utf8)!.write(to: target)

        let adapter = FilesystemCredentialAdapter(tool: .codex)
        try adapter.materialize(account: account, configDir: targetDir.path, accountStore: accountStore)

        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == creds.path)
    }

    @Test("syncBack is a no-op for symlink-based tools")
    func syncBackIsNoOp() throws {
        let account = Account(tool: .codex, displayName: "sb")
        try accountStore.save(account)
        // The symlink installed by materialize means the tool already wrote into
        // the pool — syncBack has nothing to do. It must not throw, and must not
        // require any credential to be present.
        let adapter = FilesystemCredentialAdapter(tool: .codex)
        try adapter.syncBack(account: account, configDir: nil, accountStore: accountStore)
        try adapter.syncBack(
            account: account,
            configDir: tmpDir.appendingPathComponent("anywhere").path,
            accountStore: accountStore)
    }

    @Test("materialize symlinks gemini oauth_creds.json")
    func materializeGemini() throws {
        let account = Account(tool: .gemini, displayName: "g")
        try accountStore.save(account)
        let creds = accountStore.accountDir(id: account.id, tool: .gemini)
            .appendingPathComponent("oauth_creds.json")
        try "{}".data(using: .utf8)!.write(to: creds)

        let targetDir = tmpDir.appendingPathComponent("target-gemini")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let adapter = FilesystemCredentialAdapter(tool: .gemini)
        try adapter.materialize(account: account, configDir: targetDir.path, accountStore: accountStore)

        let target = targetDir.appendingPathComponent("oauth_creds.json")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == creds.path)
    }
}

@Suite("CredentialAdapter factory")
struct CredentialAdapterFactoryTests {
    @Test("returns FilesystemCredentialAdapter for codex")
    func codexUsesFilesystem() {
        #expect(CredentialAdapters.adapter(for: .codex) is FilesystemCredentialAdapter)
    }

    @Test("returns FilesystemCredentialAdapter for gemini")
    func geminiUsesFilesystem() {
        #expect(CredentialAdapters.adapter(for: .gemini) is FilesystemCredentialAdapter)
    }

    #if os(macOS)
    @Test("returns KeychainCredentialAdapter for claude on macOS")
    func claudeUsesKeychain() {
        #expect(CredentialAdapters.adapter(for: .claude) is KeychainCredentialAdapter)
    }
    #else
    @Test("returns FilesystemCredentialAdapter for claude on non-macOS")
    func claudeUsesFilesystem() {
        #expect(CredentialAdapters.adapter(for: .claude) is FilesystemCredentialAdapter)
    }
    #endif
}

#if os(macOS)
@Suite("KeychainCredentialAdapter (macOS)", .disabled(if: ProcessInfo.processInfo.environment["CI"] != nil))
struct KeychainCredentialAdapterTests {
    var tmpDir: URL!
    var accountStore: AccountStore!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-kc-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        accountStore = AccountStore(homeURL: tmpDir)
    }

    @Test("materialize copies token to the config-dir-derived service")
    func materializeCopies() throws {
        let accountID = UUID().uuidString
        let orreryService = ClaudeKeychain.serviceName(forOrreryAccount: accountID)
        let account = Account(id: accountID, tool: .claude, displayName: "test-mac",
                              keychainItem: orreryService)
        try accountStore.save(account)

        #expect(ClaudeKeychain.storePassword("dummy-token", forOrreryAccount: accountID))

        let targetConfigDir = tmpDir.appendingPathComponent("claude-config")
        let targetService = ClaudeKeychain.service(for: targetConfigDir.path)
        defer {
            _ = KeychainTestSupport.delete(service: orreryService)
            _ = KeychainTestSupport.delete(service: targetService)
        }

        let adapter = KeychainCredentialAdapter()
        try adapter.materialize(account: account, configDir: targetConfigDir.path, accountStore: accountStore)

        #expect(ClaudeKeychain.password(forService: targetService) == "dummy-token")
    }

    @Test("materialize throws when orrery keychain item is absent")
    func throwsWhenAbsent() throws {
        let accountID = UUID().uuidString
        let account = Account(id: accountID, tool: .claude, displayName: "ghost",
                              keychainItem: ClaudeKeychain.serviceName(forOrreryAccount: accountID))
        try accountStore.save(account)
        let adapter = KeychainCredentialAdapter()
        #expect(throws: KeychainCredentialAdapter.Error.self) {
            try adapter.materialize(account: account,
                                    configDir: tmpDir.appendingPathComponent("c").path,
                                    accountStore: accountStore)
        }
    }

    @Test("materialize throws for non-claude tool")
    func throwsWrongTool() throws {
        let account = Account(tool: .codex, displayName: "x")
        try accountStore.save(account)
        let adapter = KeychainCredentialAdapter()
        #expect(throws: KeychainCredentialAdapter.Error.self) {
            try adapter.materialize(account: account,
                                    configDir: tmpDir.appendingPathComponent("c").path,
                                    accountStore: accountStore)
        }
    }

    @Test("syncBack copies the live token back into the pool service")
    func syncBackCopiesLiveToPool() throws {
        let accountID = UUID().uuidString
        let poolService = ClaudeKeychain.serviceName(forOrreryAccount: accountID)
        let account = Account(id: accountID, tool: .claude, displayName: "sb-mac",
                              keychainItem: poolService)
        try accountStore.save(account)

        // Pool starts with the original (pre-rotation) token; the live slot has
        // the refreshed token Claude just wrote on its way out.
        #expect(ClaudeKeychain.storePassword("stale-pool-token", forOrreryAccount: accountID))

        let liveConfigDir = tmpDir.appendingPathComponent("claude-config-syncback")
        let liveService = ClaudeKeychain.service(for: liveConfigDir.path)
        defer {
            _ = KeychainTestSupport.delete(service: poolService)
            _ = KeychainTestSupport.delete(service: liveService)
        }
        #expect(ClaudeKeychain.setPassword("refreshed-live-token", service: liveService))

        let adapter = KeychainCredentialAdapter()
        try adapter.syncBack(account: account, configDir: liveConfigDir.path, accountStore: accountStore)

        #expect(ClaudeKeychain.password(forService: poolService) == "refreshed-live-token")
    }

    @Test("syncBack is a safe no-op when the live slot has no credential")
    func syncBackNoLiveCredential() throws {
        let accountID = UUID().uuidString
        let poolService = ClaudeKeychain.serviceName(forOrreryAccount: accountID)
        let account = Account(id: accountID, tool: .claude, displayName: "sb-empty",
                              keychainItem: poolService)
        try accountStore.save(account)
        #expect(ClaudeKeychain.storePassword("untouched", forOrreryAccount: accountID))

        let liveConfigDir = tmpDir.appendingPathComponent("claude-config-empty")
        let liveService = ClaudeKeychain.service(for: liveConfigDir.path)
        defer { _ = KeychainTestSupport.delete(service: poolService) }
        // No item ever written at liveService — syncBack must not throw and must
        // leave the pool untouched.
        let adapter = KeychainCredentialAdapter()
        try adapter.syncBack(account: account, configDir: liveConfigDir.path, accountStore: accountStore)
        #expect(ClaudeKeychain.password(forService: poolService) == "untouched")
        _ = liveService
    }

    @Test("materialize is idempotent — second call is a safe no-op")
    func idempotent() throws {
        let accountID = UUID().uuidString
        let orreryService = ClaudeKeychain.serviceName(forOrreryAccount: accountID)
        let account = Account(id: accountID, tool: .claude, displayName: "idem",
                              keychainItem: orreryService)
        try accountStore.save(account)
        #expect(ClaudeKeychain.storePassword("tok-idem", forOrreryAccount: accountID))

        let targetConfigDir = tmpDir.appendingPathComponent("claude-config-idem")
        let targetService = ClaudeKeychain.service(for: targetConfigDir.path)
        defer {
            _ = KeychainTestSupport.delete(service: orreryService)
            _ = KeychainTestSupport.delete(service: targetService)
        }

        let adapter = KeychainCredentialAdapter()
        try adapter.materialize(account: account, configDir: targetConfigDir.path, accountStore: accountStore)
        try adapter.materialize(account: account, configDir: targetConfigDir.path, accountStore: accountStore)
        #expect(ClaudeKeychain.password(forService: targetService) == "tok-idem")
    }
}

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
