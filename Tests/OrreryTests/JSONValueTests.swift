import Testing
import Foundation
@testable import OrreryCore

@Suite("JSONValue")
struct JSONValueTests {
    @Test("round-trips object with nested types")
    func roundTrip() throws {
        let original: JSONValue = .object([
            "name": .string("orrery"),
            "ports": .array([.number(8080), .number(9090)]),
            "enabled": .bool(true),
            "meta": .object(["kind": .null]),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == original)
    }

    @Test("number preserves integer vs double round-trip")
    func numberFidelity() throws {
        let data = Data(#"{"i": 42, "d": 1.5}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let map) = value else { Issue.record("expected object"); return }
        #expect(map["i"] == .number(42))
        #expect(map["d"] == .number(1.5))
    }

    @Test("deep equality")
    func deepEquality() {
        #expect(JSONValue.object(["a": .number(1)]) == .object(["a": .number(1)]))
        #expect(JSONValue.object(["a": .number(1)]) != .object(["a": .number(2)]))
    }
}
