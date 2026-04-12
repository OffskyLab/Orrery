import Foundation

/// Gemini stores OAuth login state in `oauth_creds.json` only — no macOS Keychain entry.
public enum GeminiFlow: ToolFlow {
    public static var supportsMemoryIsolation: Bool { false }

    public static func copyLoginState(sourceDir: URL?, targetDir: URL) -> Bool {
        let src = (sourceDir ?? Tool.gemini.defaultConfigDir).appendingPathComponent("oauth_creds.json")
        let dst = targetDir.appendingPathComponent("oauth_creds.json")
        return copySingleFile(from: src, to: dst)
    }

    public static func copyNonLoginSettings(sourceDir: URL, targetDir: URL) {
        var skip: Set<String> = ["oauth_creds.json"]
        skip.formUnion(Tool.gemini.sessionSubdirectories)
        copyDirectoryContents(from: sourceDir, to: targetDir, skipping: skip)
    }
}
