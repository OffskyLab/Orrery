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
            FileHandle.standardError.write(Data("L10n codegen failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }

    static func run() throws {
        let arguments = CommandLine.arguments
        // usage: L10nCodegenTool <output.swift> <package-root> <base.json> [<other.json> ...]
        // The first locale file is the authoritative base (English). Its key set
        // defines the schema every other locale must match.
        guard arguments.count >= 4 else {
            throw ValidationError("usage: L10nCodegenTool <output.swift> <package-root> <en.json> [<other.json> ...]")
        }

        let outputURL = URL(fileURLWithPath: arguments[1])
        let packageRoot = URL(fileURLWithPath: arguments[2])
        let signatureURL = packageRoot.appendingPathComponent("Sources/OrreryCore/Resources/Localization/l10n-signatures.json")

        // Parse each remaining arg as a locale file. Infer the locale code from
        // the filename (sans extension): `en.json` → "en", `zh-Hant.json` → "zh-Hant".
        var locales: [(code: String, content: [String: String])] = []
        for path in arguments.dropFirst(3) {
            let url = URL(fileURLWithPath: path)
            let code = url.deletingPathExtension().lastPathComponent
            let content = try loadLocale(at: url)
            try validate(localeName: code, locale: content)
            locales.append((code, content))
        }
        guard let base = locales.first else {
            throw ValidationError("no locale files provided")
        }

        // Cross-validate every other locale against the base's key set + placeholders.
        for other in locales.dropFirst() {
            try validatePairs(base: base, other: other)
        }

        let signatures = try loadSignatures(at: signatureURL)
        try validateSignatures(signatures: signatures, english: base.content)

        let generated = render(signatures: signatures, locales: locales)
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

    static func validatePairs(base: (code: String, content: [String: String]),
                              other: (code: String, content: [String: String])) throws {
        let baseKeys = Set(base.content.keys)
        let otherKeys = Set(other.content.keys)
        let missingInOther = baseKeys.subtracting(otherKeys).sorted()
        let extraInOther  = otherKeys.subtracting(baseKeys).sorted()
        if !missingInOther.isEmpty || !extraInOther.isEmpty {
            var messages: [String] = []
            if !missingInOther.isEmpty {
                messages.append("Keys missing from \(other.code).json: \(missingInOther.joined(separator: ", "))")
            }
            if !extraInOther.isEmpty {
                messages.append("Extra keys in \(other.code).json (not in \(base.code).json): \(extraInOther.joined(separator: ", "))")
            }
            throw ValidationError(messages.joined(separator: "\n"))
        }

        for key in baseKeys.sorted() {
            let basePH  = placeholders(in: base.content[key]  ?? "")
            let otherPH = placeholders(in: other.content[key] ?? "")
            if basePH != otherPH {
                throw ValidationError("Placeholder mismatch for key '\(key)': \(base.code)=\(basePH.sorted()) \(other.code)=\(otherPH.sorted())")
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

    static func render(signatures: [Signature], locales: [(code: String, content: [String: String])]) -> String {
        let grouped = Dictionary(grouping: signatures, by: { $0.path[0] })
        var output: [String] = []
        output.append("import Foundation")
        output.append("")

        // Embed translations as Swift data. Keeps strings in the binary so
        // deployments don't need to ship the resource bundle alongside.
        // One `static let <propertyName>` per locale; property name is the
        // filename's lowerCamel form (`en` → `en`, `zh-Hant` → `zhHant`,
        // `ja` → `ja`).
        output.append("enum L10nData {")
        for locale in locales {
            output.append("    static let \(propertyName(forLocaleCode: locale.code)): [String: String] = [")
            for key in locale.content.keys.sorted() {
                output.append("        \"\(key)\": \(swiftQuoted(locale.content[key]!)),")
            }
            output.append("    ]")
        }
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

    /// Convert a BCP-47-ish locale code to a Swift property name:
    /// `en` → `en`, `zh-Hant` → `zhHant`, `pt-BR` → `ptBR`.
    static func propertyName(forLocaleCode code: String) -> String {
        let parts = code.split(separator: "-")
        guard let first = parts.first else { return code }
        var out = first.lowercased()
        for rest in parts.dropFirst() {
            guard let head = rest.first else { continue }
            out += head.uppercased() + rest.dropFirst()
        }
        return out
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
