import Foundation
import OrreryCore

public enum PatchSettingsExecutor {
    public static func apply(_ step: ThirdPartyStep,
                             claudeDir: URL,
                             placeholders: [String: String]) throws -> SettingsPatchRecord {
        guard case .patchSettings(let file, let rawPatch) = step else {
            throw ThirdPartyError.stepFailed(reason: "not a patchSettings step")
        }
        let patch = substitute(rawPatch, placeholders: placeholders)
        let url = claudeDir.appendingPathComponent(file)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        var target: JSONValue
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            target = try JSONDecoder().decode(JSONValue.self, from: data)
        } else {
            target = .object([:])
        }

        let record = try SettingsJSONPatcher.apply(patch: patch, to: &target, file: file)
        try writeAtomically(value: target, to: url)
        return record
    }

    public static func rollback(record: SettingsPatchRecord, claudeDir: URL) throws {
        let url = claudeDir.appendingPathComponent(record.file)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        var target = try JSONDecoder().decode(JSONValue.self,
                                              from: Data(contentsOf: url))
        try SettingsJSONPatcher.unapply(record: record, to: &target)

        if case .object(let o) = target, o.isEmpty {
            try? fm.removeItem(at: url)
            return
        }
        try writeAtomically(value: target, to: url)
    }

    // MARK: - Helpers

    private static func writeAtomically(value: JSONValue, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(value)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    /// Walks the JSON tree and replaces every occurrence of each placeholder
    /// key (e.g. `<CLAUDE_DIR>`) with the matching value inside *string* leaves.
    private static func substitute(_ value: JSONValue,
                                   placeholders: [String: String]) -> JSONValue {
        switch value {
        case .string(let s):
            var out = s
            for (k, v) in placeholders { out = out.replacingOccurrences(of: k, with: v) }
            return .string(out)
        case .array(let a):
            return .array(a.map { substitute($0, placeholders: placeholders) })
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, v) in o { out[k] = substitute(v, placeholders: placeholders) }
            return .object(out)
        default:
            return value
        }
    }
}
