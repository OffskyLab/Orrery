import Foundation

struct Signature: Decodable {
    struct Parameter: Decodable {
        let label: String
        let name: String
        let type: String
    }

    /// Bool / optional dispatch: the function doesn't substitute a placeholder,
    /// it picks one of two sibling keys based on the selector parameter.
    ///   - `type: "bool"`: `true` / `false` hold the branch sub-key names.
    ///   - `type: "optional"`: `present` / `absent` hold them instead.
    /// E.g. `memory.storageStatus` with selector `path` + `present="custom"` +
    /// `absent="default"` → dispatches to `memory.storageStatus.custom` when
    /// `path != nil`, else `memory.storageStatus.default`.
    struct Variants: Decodable {
        let selector: String
        let type: String
        let `true`: String?
        let `false`: String?
        let present: String?
        let absent: String?
    }

    let path: [String]
    let kind: String
    let parameters: [Parameter]
    let variants: Variants?
}

struct ValidationError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

@main
struct L10nCodegenTool {
    static func main() {
        do {
            try run()
        } catch {
            fputs("L10n codegen failed: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    static func run() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 5 else {
            throw ValidationError("usage: L10nCodegenTool <en.json> <zh-Hant.json> <output.swift> <package-root>")
        }

        let enURL = URL(fileURLWithPath: arguments[1])
        let zhURL = URL(fileURLWithPath: arguments[2])
        let outputURL = URL(fileURLWithPath: arguments[3])
        let packageRoot = URL(fileURLWithPath: arguments[4])
        let signatureURL = packageRoot.appendingPathComponent("Sources/OrreryCore/Resources/Localization/l10n-signatures.json")

        let english = try loadLocale(at: enURL)
        let chinese = try loadLocale(at: zhURL)
        let signatures = try loadSignatures(at: signatureURL)

        try validate(localeName: "en", locale: english)
        try validate(localeName: "zh-Hant", locale: chinese)
        try validatePairs(english: english, chinese: chinese)
        try validateSignatures(signatures: signatures, english: english)

        let generated = render(signatures: signatures, english: english, chinese: chinese)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try generated.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    static func loadLocale(at url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw ValidationError("\(url.lastPathComponent) must be a flat JSON object of string values")
        }
        return object
    }

    static func loadSignatures(at url: URL) throws -> [Signature] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([Signature].self, from: data)
    }

    static func validate(localeName: String, locale: [String: String]) throws {
        guard !locale.isEmpty else {
            throw ValidationError("\(localeName).json is empty")
        }
    }

    static func validatePairs(english: [String: String], chinese: [String: String]) throws {
        let englishKeys = Set(english.keys)
        let chineseKeys = Set(chinese.keys)
        let missingInChinese = englishKeys.subtracting(chineseKeys).sorted()
        let missingInEnglish = chineseKeys.subtracting(englishKeys).sorted()
        if !missingInChinese.isEmpty || !missingInEnglish.isEmpty {
            var messages: [String] = []
            if !missingInChinese.isEmpty {
                messages.append("Keys missing from zh-Hant.json: \(missingInChinese.joined(separator: ", "))")
            }
            if !missingInEnglish.isEmpty {
                messages.append("Keys missing from en.json: \(missingInEnglish.joined(separator: ", "))")
            }
            throw ValidationError(messages.joined(separator: "\n"))
        }

        for key in englishKeys.sorted() {
            let enPlaceholders = placeholders(in: english[key] ?? "")
            let zhPlaceholders = placeholders(in: chinese[key] ?? "")
            if enPlaceholders != zhPlaceholders {
                throw ValidationError("Placeholder mismatch for key '\(key)': en=\(enPlaceholders.sorted()) zh-Hant=\(zhPlaceholders.sorted())")
            }
        }
    }

    static func validateSignatures(signatures: [Signature], english: [String: String]) throws {
        // Build the set of keys each signature expects to be present in the locale
        // files. Plain signatures claim their own dotKey; `variants` signatures
        // claim the branch sub-keys instead (no string lives at the parent path).
        var expectedKeys: Set<String> = []
        for signature in signatures {
            let key = dotKey(for: signature.path)
            if let variants = signature.variants {
                for branch in branchSubkeys(variants).values {
                    expectedKeys.insert("\(key).\(branch)")
                }
            } else {
                expectedKeys.insert(key)
            }
        }

        let englishKeys = Set(english.keys)
        if expectedKeys != englishKeys {
            let missingInJson = expectedKeys.subtracting(englishKeys).sorted()
            let unexpectedInJson = englishKeys.subtracting(expectedKeys).sorted()
            var messages: [String] = []
            if !missingInJson.isEmpty {
                messages.append("Keys missing from en.json: \(missingInJson.joined(separator: ", "))")
            }
            if !unexpectedInJson.isEmpty {
                messages.append("Unexpected keys in en.json (not declared in signatures): \(unexpectedInJson.joined(separator: ", "))")
            }
            throw ValidationError(messages.joined(separator: "\n"))
        }

        for signature in signatures {
            let key = dotKey(for: signature.path)
            let parameterNames = Set(signature.parameters.map(\.name))

            if let variants = signature.variants {
                guard parameterNames.contains(variants.selector) else {
                    throw ValidationError("Variants selector '\(variants.selector)' for key '\(key)' is not a parameter")
                }
                // Bool selectors are pure branch switches — they never appear as
                // `{selector}` in the branch string. Optional selectors ARE
                // unwrapped into the "present" branch and may be substituted.
                let allowedPlaceholders: Set<String>
                switch variants.type {
                case "bool":     allowedPlaceholders = parameterNames.subtracting([variants.selector])
                case "optional": allowedPlaceholders = parameterNames
                default:         allowedPlaceholders = parameterNames
                }
                for branch in branchSubkeys(variants).values {
                    let variantKey = "\(key).\(branch)"
                    let placeholdersInString = Set(orderedPlaceholders(in: english[variantKey] ?? ""))
                    let extras = placeholdersInString.subtracting(allowedPlaceholders)
                    if !extras.isEmpty {
                        throw ValidationError("Unknown placeholders in '\(variantKey)': \(extras.sorted())")
                    }
                }
            } else {
                let placeholdersInString = Set(orderedPlaceholders(in: english[key] ?? ""))
                if placeholdersInString != parameterNames {
                    throw ValidationError("Signature mismatch for key '\(key)': placeholders=\(placeholdersInString.sorted()) params=\(parameterNames.sorted())")
                }
            }
        }
    }

    /// Returns `[branch-swift-selector: sub-key-name]`. For bool: swift-selector
    /// is "true"/"false" (used verbatim in the generated ternary). For optional:
    /// "present"/"absent" (generated as `let x = path { ... custom } else { ... default }`).
    static func branchSubkeys(_ variants: Signature.Variants) -> [String: String] {
        switch variants.type {
        case "bool":
            var out: [String: String] = [:]
            if let t = variants.`true`  { out["true"]  = t }
            if let f = variants.`false` { out["false"] = f }
            return out
        case "optional":
            var out: [String: String] = [:]
            if let p = variants.present { out["present"] = p }
            if let a = variants.absent  { out["absent"]  = a }
            return out
        default:
            return [:]
        }
    }

    static func render(signatures: [Signature], english: [String: String], chinese: [String: String]) -> String {
        let grouped = Dictionary(grouping: signatures, by: { $0.path[0] })
        var output: [String] = []
        output.append("import Foundation")
        output.append("")

        // Embed translations as Swift data. Keeps strings in the binary so
        // deployments don't need to ship the resource bundle alongside.
        output.append("enum L10nData {")
        output.append("    static let en: [String: String] = [")
        for key in english.keys.sorted() {
            output.append("        \"\(key)\": \(swiftQuoted(english[key]!)),")
        }
        output.append("    ]")
        output.append("    static let zhHant: [String: String] = [")
        for key in chinese.keys.sorted() {
            output.append("        \"\(key)\": \(swiftQuoted(chinese[key]!)),")
        }
        output.append("    ]")
        output.append("}")
        output.append("")

        output.append("public enum L10n {")
        for namespace in grouped.keys.sorted() {
            output.append("    public enum \(namespace) {")
            let items = grouped[namespace]!.sorted { lhs, rhs in lhs.path[1] < rhs.path[1] }
            for item in items {
                let key = dotKey(for: item.path)
                if item.kind == "var" {
                    output.append("        public static var \(item.path[1]): String {")
                    output.append("            Localizer.string(\"\(key)\")")
                    output.append("        }")
                } else {
                    let parameters = item.parameters.map { parameter in
                        // Omit redundant label when it matches the param name
                        // (Swift default behavior), emit `_ name:` for unlabeled,
                        // and `label name:` when they genuinely differ.
                        if parameter.label == parameter.name {
                            return "\(parameter.name): \(parameter.type)"
                        } else {
                            return "\(parameter.label) \(parameter.name): \(parameter.type)"
                        }
                    }.joined(separator: ", ")
                    output.append("        public static func \(item.path[1])(\(parameters)) -> String {")
                    output.append(contentsOf: renderBody(item: item, key: key).map { "            " + $0 })
                    output.append("        }")
                }
            }
            output.append("    }")
            output.append("")
        }
        output.append("}")
        return output.joined(separator: "\n")
    }

    /// Render the body of a function accessor (without the surrounding
    /// `func name(...) -> String { ... }` lines). Returned lines are not
    /// indented; caller prepends namespace-level indentation.
    static func renderBody(item: Signature, key: String) -> [String] {
        let nonSelectorArgs = item.parameters
            .filter { $0.name != item.variants?.selector }
            .map { "\"\($0.name)\": \(argExpression(for: $0))" }
            .joined(separator: ", ")
        let argsDict = nonSelectorArgs.isEmpty ? "[:]" : "[\(nonSelectorArgs)]"

        guard let variants = item.variants else {
            if item.parameters.isEmpty {
                return ["Localizer.string(\"\(key)\")"]
            }
            // Plain path: single key, all params are placeholder substitutions.
            let entries = item.parameters
                .map { "\"\($0.name)\": \(argExpression(for: $0))" }
                .joined(separator: ", ")
            return ["Localizer.format(\"\(key)\", [\(entries)])"]
        }

        switch variants.type {
        case "bool":
            let t = variants.`true` ?? "true"
            let f = variants.`false` ?? "false"
            return ["Localizer.format(\"\(key).\\(\(variants.selector) ? \"\(t)\" : \"\(f)\")\", \(argsDict))"]
        case "optional":
            let presentBranch = variants.present ?? "present"
            let absentBranch  = variants.absent  ?? "absent"
            // Use `if let <name> = <name> { ... }` so the placeholder substitution
            // gets the unwrapped value.
            return [
                "if let \(variants.selector) = \(variants.selector) {",
                "    return Localizer.format(\"\(key).\(presentBranch)\", \(argsDict.replacingOccurrences(of: "String(describing: \(variants.selector))", with: variants.selector)))",
                "}",
                "return Localizer.string(\"\(key).\(absentBranch)\")",
            ]
        default:
            return ["Localizer.string(\"\(key)\")"]
        }
    }

    /// How to stringify a parameter in the `Localizer.format` dictionary.
    /// String / Int / Double → pass-through or interpolation; Optional gets
    /// unwrapped by the caller before reaching here (we never substitute a
    /// placeholder with an Optional value).
    static func argExpression(for parameter: Signature.Parameter) -> String {
        switch parameter.type {
        case "String": return parameter.name
        default:       return "String(describing: \(parameter.name))"
        }
    }

    /// Escape a string for safe embedding inside `"..."` in Swift source.
    static func swiftQuoted(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.asciiValue.map({ $0 < 0x20 }) == true {
                    out += String(format: "\\u{%04X}", ch.asciiValue!)
                } else {
                    out.append(ch)
                }
            }
        }
        out += "\""
        return out
    }

    static func dotKey(for path: [String]) -> String {
        lowerCamel(path[0]) + "." + lowerCamel(path[1])
    }

    static func lowerCamel(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.lowercased() + value.dropFirst()
    }

    static func placeholders(in string: String) -> Set<String> {
        Set(orderedPlaceholders(in: string))
    }

    static func orderedPlaceholders(in string: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"\{([A-Za-z_][A-Za-z0-9_]*)\}"#)
        let nsString = string as NSString
        let matches = regex.matches(in: string, range: NSRange(location: 0, length: nsString.length))
        var ordered: [String] = []
        for match in matches {
            let placeholder = nsString.substring(with: match.range(at: 1))
            if !ordered.contains(placeholder) {
                ordered.append(placeholder)
            }
        }
        return ordered
    }
}
