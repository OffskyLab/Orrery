import Foundation
import OrreryCore

/// Pure deep-merge + undo logic for `settings.json`. No IO; callers pass values in,
/// values out, and a `SettingsPatchRecord` describing exactly what was changed.
public enum SettingsJSONPatcher {
    /// Merges `patch` into `target` at the top level and records the before-state
    /// of every touched key so `unapply` can reverse it.
    public static func apply(patch: JSONValue, to target: inout JSONValue,
                             file: String = "settings.json") throws -> SettingsPatchRecord {
        guard case .object(var targetObj) = target else {
            throw ThirdPartyError.stepFailed(reason: "settings root must be an object")
        }
        guard case .object(let patchObj) = patch else {
            throw ThirdPartyError.stepFailed(reason: "patch root must be an object")
        }

        var entries: [SettingsPatchRecord.Entry] = []
        for (key, patchValue) in patchObj {
            merge(keyPath: [key],
                  target: &targetObj[key],
                  patch: patchValue,
                  entries: &entries)
        }
        target = .object(targetObj)
        return .init(file: file, entries: entries)
    }

    private static func merge(keyPath: [String],
                              target: inout JSONValue?,
                              patch: JSONValue,
                              entries: inout [SettingsPatchRecord.Entry]) {
        // Case 1: target absent → write patch, record .absent.
        guard let existing = target else {
            target = patch
            entries.append(.init(keyPath: keyPath, before: .absent))
            return
        }

        // Case 2: both sides are objects → recurse per child, track added keys.
        if case .object(var existingObj) = existing, case .object(let patchObj) = patch {
            var addedKeys: [String] = []
            for (k, v) in patchObj {
                if existingObj[k] == nil { addedKeys.append(k) }
                var child: JSONValue? = existingObj[k]
                merge(keyPath: keyPath + [k], target: &child, patch: v, entries: &entries)
                existingObj[k] = child
            }
            target = .object(existingObj)
            if !addedKeys.isEmpty {
                entries.append(.init(keyPath: keyPath, before: .object(addedKeys: addedKeys)))
            }
            return
        }

        // Case 3 (new): both sides are arrays → append-if-not-equal.
        if case .array(var existingArr) = existing, case .array(let patchArr) = patch {
            var appended: [JSONValue] = []
            for element in patchArr {
                if !existingArr.contains(where: { areEqual($0, element, keyPath: keyPath) }) {
                    existingArr.append(element)
                    appended.append(element)
                }
            }
            target = .array(existingArr)
            if !appended.isEmpty {
                entries.append(.init(keyPath: keyPath,
                                     before: .array(appendedElements: appended)))
            }
            return
        }

        // Case 4: fallthrough — overwrite scalar / type mismatch.
        target = patch
        entries.append(.init(keyPath: keyPath, before: .scalar(previous: existing)))
    }

    /// Reverses a previously recorded patch. Safe to call on a target whose
    /// schema has grown since apply (extra keys/elements the user added are
    /// left alone).
    public static func unapply(record: SettingsPatchRecord,
                               to target: inout JSONValue) throws {
        guard case .object = target else {
            throw ThirdPartyError.stepFailed(reason: "settings root must be an object")
        }
        // Reverse order so nested entries undo before their parents.
        for entry in record.entries.reversed() {
            try reverse(entry, at: entry.keyPath, in: &target)
        }
    }

    private static func reverse(_ entry: SettingsPatchRecord.Entry,
                                at path: [String],
                                in root: inout JSONValue) throws {
        guard !path.isEmpty else {
            throw ThirdPartyError.stepFailed(reason: "empty keyPath")
        }
        try mutate(at: path, in: &root) { slot in
            switch entry.before {
            case .absent:
                slot = nil
            case .scalar(let previous):
                slot = previous
            case .object(let addedKeys):
                guard case .object(var obj) = slot else { return }
                for k in addedKeys { obj.removeValue(forKey: k) }
                slot = .object(obj)
            case .array(let appended):
                guard case .array(var arr) = slot else { return }
                // Remove in reverse by exact equality (hook-matcher comparator
                // is not needed here because we stored the resolved values).
                for element in appended {
                    if let idx = arr.lastIndex(where: { $0 == element }) {
                        arr.remove(at: idx)
                    }
                }
                slot = .array(arr)
            }
        }
    }

    private static func mutate(at path: [String],
                               in root: inout JSONValue,
                               _ transform: (inout JSONValue?) -> Void) throws {
        if path.count == 1 {
            guard case .object(var obj) = root else {
                throw ThirdPartyError.stepFailed(reason: "expected object at root")
            }
            var slot: JSONValue? = obj[path[0]]
            transform(&slot)
            if let slot { obj[path[0]] = slot } else { obj.removeValue(forKey: path[0]) }
            root = .object(obj)
            return
        }
        guard case .object(var obj) = root,
              var child = obj[path[0]] else {
            return // nothing to reverse — the user already cleaned up
        }
        try mutate(at: Array(path.dropFirst()), in: &child, transform)
        obj[path[0]] = child
        root = .object(obj)
    }

    internal static func areEqual(_ a: JSONValue, _ b: JSONValue,
                                  keyPath: [String]) -> Bool {
        // Hook-matcher shape check: objects with a `hooks` child that is
        // itself an array of `{type, command}` objects.
        if let aSig = hookMatcherSignature(a), let bSig = hookMatcherSignature(b) {
            return aSig == bSig
        }
        return a == b
    }

    private struct HookSignature: Equatable {
        let matcher: String?
        let commands: Set<String>
    }

    private static func hookMatcherSignature(_ v: JSONValue) -> HookSignature? {
        guard case .object(let obj) = v,
              case .array(let inner) = obj["hooks"] else { return nil }

        var commands = Set<String>()
        for element in inner {
            guard case .object(let eo) = element,
                  case .string(let cmd) = eo["command"] else { return nil }
            commands.insert(cmd)
        }

        let matcher: String?
        switch obj["matcher"] {
        case .some(.string(let s)): matcher = s
        case .none: matcher = nil
        default: return nil
        }

        return HookSignature(matcher: matcher, commands: commands)
    }
}
