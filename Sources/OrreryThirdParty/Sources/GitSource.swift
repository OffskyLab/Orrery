import Foundation
import OrreryCore

public struct GitSource: ThirdPartySourceFetcher {
    public init() {}

    /// True when `ref` matches `[0-9a-f]{40}`.
    func isResolvedSHA(_ ref: String) -> Bool {
        guard ref.count == 40 else { return false }
        return ref.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    func cacheDir(root: URL, packageID: String, sha: String) -> URL {
        root.appendingPathComponent(packageID).appendingPathComponent("@\(sha)")
    }

    public func fetch(source: ThirdPartySource,
                      cacheRoot: URL,
                      packageID: String,
                      refOverride: String?,
                      forceRefresh: Bool) throws -> (URL, String) {
        guard case .git(let url, let manifestRef) = source else {
            throw ThirdPartyError.sourceFetchFailed(reason: "GitSource only supports git source")
        }
        var requestedRef = refOverride ?? manifestRef
        if requestedRef == "latest" {
            requestedRef = try resolveLatestTag(url: url)
        }
        let sha = try resolveSHA(url: url, ref: requestedRef)
        let dir = cacheDir(root: cacheRoot, packageID: packageID, sha: sha)

        let fm = FileManager.default
        if forceRefresh, fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try clone(url: url, ref: requestedRef, sha: sha, into: dir)
        }
        return (dir, sha)
    }

    /// Picks the newest version tag from the remote, sorted by semver (`-v:refname`).
    /// Used when the manifest opts into auto-bumping by writing `"ref": "latest"`.
    private func resolveLatestTag(url: String) throws -> String {
        let out = try runGit(["-c", "versionsort.suffix=-",
                              "ls-remote", "--tags", "--refs",
                              "--sort=-v:refname", url])
        // ls-remote output: "<sha>\t<refs/tags/NAME>\n". Strip the prefix and
        // pick the first entry — the highest version after semver sort.
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2 else { continue }
            let refName = String(parts[1])
            let prefix = "refs/tags/"
            guard refName.hasPrefix(prefix) else { continue }
            let tag = String(refName.dropFirst(prefix.count))
            return tag
        }
        throw ThirdPartyError.sourceFetchFailed(
            reason: "no version tags found at \(url) — cannot resolve `latest`"
        )
    }

    private func resolveSHA(url: String, ref: String) throws -> String {
        if isResolvedSHA(ref) { return ref }
        let out = try runGit(["ls-remote", url, ref])
        // ls-remote output: "<sha>\t<ref>\n"; take the first SHA token.
        guard let line = out.split(separator: "\n").first,
              let sha = line.split(separator: "\t").first,
              sha.count == 40 else {
            throw ThirdPartyError.sourceFetchFailed(reason: "git ls-remote returned no match for \(ref)")
        }
        return String(sha)
    }

    private func clone(url: String, ref: String, sha: String, into dir: URL) throws {
        // Two cases:
        //  1. ref is a branch/tag — clone with --depth 1 --branch.
        //  2. ref is a pure SHA — clone default branch then checkout SHA.
        if isResolvedSHA(ref) {
            _ = try runGit(["clone", "--filter=blob:none", "--no-checkout", url, dir.path])
            _ = try runGit(["-C", dir.path, "checkout", sha])
        } else {
            _ = try runGit(["clone", "--depth", "1", "--branch", ref, url, dir.path])
        }
    }

    private func runGit(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? "git failed"
            throw ThirdPartyError.sourceFetchFailed(reason: msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
