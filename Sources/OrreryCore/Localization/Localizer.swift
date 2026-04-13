import Foundation

/// Thin runtime over the codegen-embedded `L10nData` dictionaries.
/// The JSON files under `Resources/Localization/` are the authoring source;
/// the build plugin copies their contents into `L10n+Generated.swift` as
/// Swift dictionaries so the binary stays self-contained (no bundle needed
/// at install time).
public enum Localizer {
    private static let fallbackLocale: AppLocale = .en

    public static func string(_ key: String) -> String {
        if let value = table(for: AppLocale.current)[key] {
            return value
        }
        if let fallback = table(for: fallbackLocale)[key] {
            return fallback
        }
        #if DEBUG
        assertionFailure("Missing localization key: \(key)")
        #endif
        return key
    }

    public static func format(_ key: String, _ args: [String: String]) -> String {
        var value = string(key)
        for (placeholder, replacement) in args {
            value = value.replacingOccurrences(of: "{\(placeholder)}", with: replacement)
        }
        return value
    }

    private static func table(for locale: AppLocale) -> [String: String] {
        switch locale {
        case .en:     return L10nData.en
        case .zhHant: return L10nData.zhHant
        case .ja:     return L10nData.ja
        }
    }
}
