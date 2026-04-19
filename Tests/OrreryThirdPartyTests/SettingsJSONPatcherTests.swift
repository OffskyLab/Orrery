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

@Suite("SettingsJSONPatcher — objects")
struct SettingsJSONPatcherObjectTests {
    @Test("recursive merge only records added child keys")
    func recursiveMergeRecordsAddedKeys() throws {
        var target: JSONValue = .object([
            "env": .object(["EXISTING": .string("value")])
        ])
        let patch: JSONValue = .object([
            "env": .object(["NEW": .string("added")])
        ])
        let record = try SettingsJSONPatcher.apply(patch: patch, to: &target)

        guard case .object(let out) = target,
              case .object(let envObj) = out["env"] else {
            Issue.record("expected env object"); return
        }
        #expect(envObj["EXISTING"] == .string("value"))
        #expect(envObj["NEW"] == .string("added"))
        let parentEntry = record.entries.first(where: { $0.keyPath == ["env"] })
        #expect(parentEntry?.before == .object(addedKeys: ["NEW"]))
    }

    @Test("recursive merge overwriting an existing child is recorded as scalar")
    func recursiveMergeOverwritesChildScalar() throws {
        var target: JSONValue = .object([
            "env": .object(["K": .string("old")])
        ])
        let patch: JSONValue = .object([
            "env": .object(["K": .string("new")])
        ])
        let record = try SettingsJSONPatcher.apply(patch: patch, to: &target)

        let entry = record.entries.first(where: { $0.keyPath == ["env", "K"] })
        #expect(entry?.before == .scalar(previous: .string("old")))
    }
}

@Suite("SettingsJSONPatcher — arrays (deep equal)")
struct SettingsJSONPatcherArrayTests {
    @Test("appends new elements, records them")
    func appendsNewElements() throws {
        var target: JSONValue = .object(["xs": .array([.number(1)])])
        let patch: JSONValue = .object(["xs": .array([.number(1), .number(2)])])
        let record = try SettingsJSONPatcher.apply(patch: patch, to: &target)

        guard case .object(let o) = target, case .array(let xs) = o["xs"] else {
            Issue.record("expected xs array"); return
        }
        #expect(xs == [.number(1), .number(2)])
        let entry = record.entries.first(where: { $0.keyPath == ["xs"] })
        #expect(entry?.before == .array(appendedElements: [.number(2)]))
    }

    @Test("does not duplicate existing elements")
    func noDuplicates() throws {
        var target: JSONValue = .object(["xs": .array([.number(1), .number(2)])])
        let patch: JSONValue = .object(["xs": .array([.number(1)])])
        let record = try SettingsJSONPatcher.apply(patch: patch, to: &target)

        guard case .object(let o) = target, case .array(let xs) = o["xs"] else {
            Issue.record("expected xs array"); return
        }
        #expect(xs == [.number(1), .number(2)])
        let entry = record.entries.first(where: { $0.keyPath == ["xs"] })
        #expect(entry == nil || entry?.before == .array(appendedElements: []))
    }
}
