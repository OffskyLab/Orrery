import Foundation
import OrreryCore

public enum CopyFileExecutor {
    /// Copies the file and returns its destination path relative to `claudeDir`.
    public static func apply(_ step: ThirdPartyStep,
                             sourceDir: URL, claudeDir: URL) throws -> [String] {
        guard case .copyFile(let from, let to) = step else {
            throw ThirdPartyError.stepFailed(reason: "not a copyFile step")
        }
        let src = sourceDir.appendingPathComponent(from)
        let dst = claudeDir.appendingPathComponent(to)
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: src, to: dst)
        return [to]
    }

    public static func rollback(paths: [String], claudeDir: URL) {
        let fm = FileManager.default
        for p in paths {
            try? fm.removeItem(at: claudeDir.appendingPathComponent(p))
        }
    }
}
