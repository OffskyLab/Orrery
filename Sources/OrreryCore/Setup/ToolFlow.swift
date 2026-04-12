import Foundation

/// Per-tool behavior for create / tools wizards.
/// Each tool implements this protocol with tool-specific file/credential handling.
/// Conformers live in `{Tool}Flow.swift` alongside this file.
public protocol ToolFlow {
    /// Copy login state (credentials + account config) into the new env's tool config dir.
    /// - Parameters:
    ///   - sourceDir: source tool config dir, or `nil` to copy from the tool's origin/system-default location.
    ///   - targetDir: the new env's tool config dir. Created if missing.
    /// - Returns: true if the essential credential state was copied successfully.
    static func copyLoginState(sourceDir: URL?, targetDir: URL) -> Bool

    /// Copy non-login settings (plugins, skills, preferences; NOT credentials) from source to target.
    /// `sourceDir` is always an actual directory (use `Tool.defaultConfigDir` for origin).
    /// No-ops if `sourceDir` doesn't exist.
    static func copyNonLoginSettings(sourceDir: URL, targetDir: URL)

    /// Whether this tool supports per-env memory isolation.
    /// When false, the create wizard skips the memory-isolation step for this tool.
    static var supportsMemoryIsolation: Bool { get }
}

public extension Tool {
    /// Dispatches to the concrete `ToolFlow` implementation for this tool.
    var flowType: any ToolFlow.Type {
        switch self {
        case .claude: return ClaudeFlow.self
        case .codex:  return CodexFlow.self
        case .gemini: return GeminiFlow.self
        }
    }
}

// MARK: - Shared helpers

public extension ToolFlow {
    /// Copy entries from `sourceDir` into `targetDir`, skipping the given names.
    /// Existing entries in `targetDir` are not overwritten (preserves session symlinks).
    static func copyDirectoryContents(from sourceDir: URL, to targetDir: URL, skipping: Set<String>) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceDir.path) else { return }
        try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let items = (try? fm.contentsOfDirectory(atPath: sourceDir.path)) ?? []
        for item in items where !skipping.contains(item) {
            let src = sourceDir.appendingPathComponent(item)
            let dst = targetDir.appendingPathComponent(item)
            if fm.fileExists(atPath: dst.path) { continue }
            try? fm.copyItem(at: src, to: dst)
        }
    }

    /// Copy a single file from `src` to `dst`, overwriting if `dst` exists.
    /// Creates parent directories as needed. Returns false if `src` doesn't exist or the copy fails.
    static func copySingleFile(from src: URL, to dst: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return false }
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dst)
        do { try fm.copyItem(at: src, to: dst); return true } catch { return false }
    }
}
