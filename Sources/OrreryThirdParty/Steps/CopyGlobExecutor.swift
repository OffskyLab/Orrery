import Foundation
import OrreryCore

public enum CopyGlobExecutor {
    public static func apply(_ step: ThirdPartyStep,
                             sourceDir: URL, claudeDir: URL) throws -> [String] {
        guard case .copyGlob(let from, let toDir) = step else {
            throw ThirdPartyError.stepFailed(reason: "not a copyGlob step")
        }
        // v1 supports only the "<dir>/*.ext" shape used by cc-statusline.
        let parts = from.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].contains("*"), parts[1].hasPrefix("*.") else {
            throw ThirdPartyError.stepFailed(reason: "copyGlob only supports <dir>/*.ext patterns (got \(from))")
        }
        let srcSubdir = sourceDir.appendingPathComponent(parts[0])
        let ext = String(parts[1].dropFirst(2))
        let dstDir = claudeDir.appendingPathComponent(toDir)
        let fm = FileManager.default
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)

        var copied: [String] = []
        let contents = (try? fm.contentsOfDirectory(atPath: srcSubdir.path)) ?? []
        for name in contents where (name as NSString).pathExtension == ext {
            let src = srcSubdir.appendingPathComponent(name)
            let dst = dstDir.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
            copied.append("\(toDir)/\(name)")
        }
        return copied
    }

    public static func rollback(paths: [String], claudeDir: URL) {
        CopyFileExecutor.rollback(paths: paths, claudeDir: claudeDir)
    }
}
