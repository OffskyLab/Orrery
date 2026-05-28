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

    @Test("returns NoOpCredentialAdapter for claude")
    func claudeUsesNoOp() {
        #expect(CredentialAdapters.adapter(for: .claude) is NoOpCredentialAdapter)
    }
}

@Suite("NoOpCredentialAdapter")
struct NoOpCredentialAdapterTests {
    var tmpDir: URL!
    var accountStore: AccountStore!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-noop-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        accountStore = AccountStore(homeURL: tmpDir)
    }

    @Test("materialize is a no-op — does not throw")
    func materializeIsNoOp() throws {
        let account = Account(tool: .claude, displayName: "test-noop")
        try accountStore.save(account)
        let adapter = NoOpCredentialAdapter()
        try adapter.materialize(account: account, configDir: tmpDir.path, accountStore: accountStore)
    }

    @Test("syncBack is a no-op — does not throw")
    func syncBackIsNoOp() throws {
        let account = Account(tool: .claude, displayName: "test-noop-sb")
        try accountStore.save(account)
        let adapter = NoOpCredentialAdapter()
        try adapter.syncBack(account: account, configDir: tmpDir.path, accountStore: accountStore)
    }
}
