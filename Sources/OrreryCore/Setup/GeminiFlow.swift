import Foundation

/// Gemini stores OAuth login state in `oauth_creds.json` only — no macOS Keychain entry.
public enum GeminiFlow: ToolFlow {
    public static var supportsMemoryIsolation: Bool { false }

    public static func copyLoginState(sourceDir: URL?, targetDir: URL) -> Bool {
        // The tool's own default now comes from the registry, so a
        // plugin-provided tool answers for itself. Nil means its plugin did
        // not load: there is no source to copy the login state from, and
        // `false` reports that honestly. Returning `true` here would be the
        // failure the spec names — an action that may not have happened,
        // reported as done.
        guard let sourceRoot = sourceDir ?? Tool.gemini.configDir() else { return false }
        let src = sourceRoot.appendingPathComponent("oauth_creds.json")
        let dst = targetDir.appendingPathComponent("oauth_creds.json")
        return copySingleFile(from: src, to: dst)
    }

    public static func copyNonLoginSettings(sourceDir: URL, targetDir: URL) {
        var skip: Set<String> = ["oauth_creds.json"]
        skip.formUnion(Tool.gemini.sessionSubdirectories)
        copyDirectoryContents(from: sourceDir, to: targetDir, skipping: skip)
    }
}
