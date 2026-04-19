import Testing
import Foundation
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("SettingsJSONPatcher — basics")
struct SettingsJSONPatcherBasicsTests {
    @Test("empty target + patch writes full object, all before = absent")
    func emptyTargetFullPatch() throws {
        var target: JSONValue = .object([:])
        let patch: JSONValue = .object([
            "statusLine": .object(["type": .string("command")]),
        ])
        let record = try SettingsJSONPatcher.apply(patch: patch, to: &target)

        #expect(target == patch)
        #expect(record.entries.count == 1)
        #expect(record.entries[0].keyPath == ["statusLine"])
        #expect(record.entries[0].before == .absent)
    }

    @Test("overwrite existing scalar records previous value")
    func scalarOverwrite() throws {
        var target: JSONValue = .object(["model": .string("old")])
        let patch: JSONValue = .object(["model": .string("new")])
        let record = try SettingsJSONPatcher.apply(patch: patch, to: &target)

        guard case .object(let out) = target else { Issue.record("expected object"); return }
        #expect(out["model"] == .string("new"))
        #expect(record.entries.count == 1)
        #expect(record.entries[0].before == .scalar(previous: .string("old")))
    }
}
