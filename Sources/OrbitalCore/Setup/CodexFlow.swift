import Foundation

/// Codex stores login state in `auth.json` only — no macOS Keychain entry.
public enum CodexFlow: ToolFlow {
    public static var supportsMemoryIsolation: Bool { false }

    public static func copyLoginState(sourceDir: URL?, targetDir: URL) -> Bool {
        let src = (sourceDir ?? Tool.codex.defaultConfigDir).appendingPathComponent("auth.json")
        let dst = targetDir.appendingPathComponent("auth.json")
        return copySingleFile(from: src, to: dst)
    }

    public static func copyNonLoginSettings(sourceDir: URL, targetDir: URL) {
        var skip: Set<String> = ["auth.json"]
        skip.formUnion(Tool.codex.sessionSubdirectories)
        copyDirectoryContents(from: sourceDir, to: targetDir, skipping: skip)
    }
}
