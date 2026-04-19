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
            let existing = targetObj[key]
            let (merged, before) = mergeTop(existing: existing, patch: patchValue)
            targetObj[key] = merged
            entries.append(.init(keyPath: [key], before: before))
        }
        target = .object(targetObj)
        return .init(file: file, entries: entries)
    }

    /// Top-level merge for a single key. Placeholder implementation that only
    /// handles `scalar overwrite` and `absent insert`; later tasks extend it
    /// for objects, arrays, and the hook-matcher comparator.
    private static func mergeTop(existing: JSONValue?, patch: JSONValue)
    -> (JSONValue, SettingsPatchRecord.BeforeState) {
        guard let existing else {
            return (patch, .absent)
        }
        return (patch, .scalar(previous: existing))
    }
}
