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
            keychainItem: "Claude Code-orrery-550e8400"
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
    }
}
