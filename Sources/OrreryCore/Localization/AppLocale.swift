import Foundation

public enum AppLocale: Sendable {
    case en
    case zhHant
    case ja

    public static let current: AppLocale = detect()

    private static func detect() -> AppLocale {
        let env = ProcessInfo.processInfo.environment

        // Check LC_ALL, LC_MESSAGES, LANG in priority order (skip empty strings)
        let raw: String
        if let v = env["LC_ALL"], !v.isEmpty { raw = v }
        else if let v = env["LC_MESSAGES"], !v.isEmpty { raw = v }
        else if let v = env["LANG"], !v.isEmpty { raw = v }
        else { raw = "en_US.UTF-8" }

        if raw.hasPrefix("zh_TW") || raw.hasPrefix("zh_Hant") {
            return .zhHant
        }
        if raw.hasPrefix("ja") {
            return .ja
        }
        return .en
    }
}
