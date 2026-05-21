import Testing
import Foundation
@testable import OrreryCore

@Suite("Account model")
struct AccountModelTests {
    @Test("encodes and decodes with iso8601 dates")
    func roundTrip() throws {
        let account = Account(
            id: "550e8400-e29b-41d4-a716-446655440000",
            tool: .claude,
            displayName: "work",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            keychainItem: "Claude Code-orrery-550e8400",
            email: "work@example.com",
            plan: "max"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(account)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Account.self, from: data)

        #expect(decoded.id == account.id)
        #expect(decoded.tool == .claude)
        #expect(decoded.displayName == "work")
        #expect(decoded.keychainItem == "Claude Code-orrery-550e8400")
        #expect(decoded.createdAt == account.createdAt)
        #expect(decoded.email == "work@example.com")
        #expect(decoded.plan == "max")
    }

    @Test("keychainItem optional for non-macOS-claude accounts")
    func keychainItemOptional() throws {
        let account = Account(
            id: UUID().uuidString,
            tool: .codex,
            displayName: "personal",
            createdAt: Date()
        )
        #expect(account.keychainItem == nil)
        #expect(account.email == nil)
        #expect(account.plan == nil)
    }

    @Test("old metadata.json without email/plan keys decodes with nils")
    func legacyDecode() throws {
        // Matches what a pre-v2.8.1 metadata.json looks like — no email, no plan.
        let legacyJSON = """
            {
              "id": "abc123",
              "tool": "claude",
              "displayName": "legacy",
              "createdAt": "2024-01-01T00:00:00Z",
              "keychainItem": "Claude Code-orrery-abc123"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Account.self, from: Data(legacyJSON.utf8))

        #expect(decoded.id == "abc123")
        #expect(decoded.tool == .claude)
        #expect(decoded.displayName == "legacy")
        #expect(decoded.keychainItem == "Claude Code-orrery-abc123")
        #expect(decoded.email == nil)
        #expect(decoded.plan == nil)
    }
}

@Suite("AccountStore")
struct AccountStoreTests {
    var tmpDir: URL!
    var store: AccountStore!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-acct-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = AccountStore(homeURL: tmpDir)
    }

    @Test("save creates accounts/<tool>/<id>/metadata.json")
    func saveCreatesFile() throws {
        let account = Account(tool: .claude, displayName: "work")
        try store.save(account)

        let path = tmpDir
            .appendingPathComponent("accounts/claude/\(account.id)/metadata.json")
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    @Test("load returns saved account")
    func loadReturnsSaved() throws {
        let original = Account(tool: .codex, displayName: "personal")
        try store.save(original)
        let loaded = try store.load(id: original.id, tool: .codex)
        #expect(loaded.displayName == "personal")
    }

    @Test("load throws when id missing")
    func loadMissing() throws {
        #expect(throws: AccountStore.Error.self) {
            try store.load(id: "nonexistent", tool: .claude)
        }
    }

    @Test("list returns all accounts for a tool")
    func listByTool() throws {
        try store.save(Account(tool: .claude, displayName: "work"))
        try store.save(Account(tool: .claude, displayName: "personal"))
        try store.save(Account(tool: .codex, displayName: "work"))

        let claudeAccounts = try store.list(tool: .claude)
        #expect(claudeAccounts.count == 2)
        #expect(Set(claudeAccounts.map(\.displayName)) == ["work", "personal"])
    }

    @Test("listAll groups by tool")
    func listAll() throws {
        try store.save(Account(tool: .claude, displayName: "a"))
        try store.save(Account(tool: .gemini, displayName: "b"))
        let all = try store.listAll()
        #expect(all[.claude]?.count == 1)
        #expect(all[.gemini]?.count == 1)
        #expect(all[.codex] == nil || all[.codex]?.isEmpty == true)
    }

    @Test("delete removes account dir")
    func deleteRemovesDir() throws {
        let account = Account(tool: .claude, displayName: "old")
        try store.save(account)
        try store.delete(id: account.id, tool: .claude)
        #expect(throws: AccountStore.Error.self) {
            try store.load(id: account.id, tool: .claude)
        }
    }

    @Test("findByDisplayName matches case-sensitively")
    func findByDisplayName() throws {
        let acct = Account(tool: .claude, displayName: "Work")
        try store.save(acct)
        #expect(try store.findByDisplayName("Work", tool: .claude)?.id == acct.id)
        #expect(try store.findByDisplayName("work", tool: .claude) == nil)
    }
}
