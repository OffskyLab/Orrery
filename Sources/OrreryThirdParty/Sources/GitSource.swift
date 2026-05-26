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
                      forceRefresh: Bool) throws -> FetchedRef {
        guard case .git(let url, let manifestRef) = source else {
            throw ThirdPartyError.sourceFetchFailed(reason: "GitSource only supports git source")
        }
        var requestedRef = refOverride ?? manifestRef
        if requestedRef == "latest" {
            requestedRef = try resolveLatestTag(url: url)
        }

        // Resolve to a commit SHA + classify (tag / branch / raw SHA) so the
        // success message can show the tag name when one is available and the
        // SHA otherwise.
        let resolved = try resolveRef(url: url, ref: requestedRef)

        let dir = cacheDir(root: cacheRoot, packageID: packageID, sha: resolved.sha)
        let fm = FileManager.default
        if forceRefresh, fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try clone(url: url, ref: requestedRef, sha: resolved.sha, into: dir)
        }
        return FetchedRef(dir: dir, sha: resolved.sha,
                          displayLabel: resolved.tagName)
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

    /// Resolves `ref` against the remote and returns the underlying commit SHA
    /// plus the tag name when applicable. One round-trip queries:
    ///   - `refs/tags/<ref>`       → annotated tag object (or commit for lightweight)
    ///   - `refs/tags/<ref>^{}`    → peeled commit for annotated tags
    ///   - `refs/heads/<ref>`      → branch tip
    ///
    /// For annotated tags the peeled line is the actual commit; without
    /// `^{}` peeling we'd hand out the tag-object SHA, which is what was
    /// previously surfaced in `latest@b7e6d96` — a hash users couldn't find
    /// in `git log`.
    private func resolveRef(url: String, ref: String) throws -> (sha: String, tagName: String?) {
        if isResolvedSHA(ref) {
            return (sha: ref, tagName: nil)
        }
        let out = try runGit(["ls-remote", url,
                              "refs/tags/\(ref)",
                              "refs/tags/\(ref)^{}",
                              "refs/heads/\(ref)"])
        var tagObject: String? = nil
        var tagPeeled: String? = nil
        var branchHead: String? = nil
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2 else { continue }
            let sha = String(parts[0])
            guard sha.count == 40 else { continue }
            let refName = String(parts[1])
            if refName == "refs/tags/\(ref)^{}" { tagPeeled = sha }
            else if refName == "refs/tags/\(ref)" { tagObject = sha }
            else if refName == "refs/heads/\(ref)" { branchHead = sha }
        }
        if let sha = tagPeeled ?? tagObject {
            return (sha: sha, tagName: ref)
        }
        if let sha = branchHead {
            return (sha: sha, tagName: nil)
        }
        // Last resort: bare ls-remote (covers things like `HEAD` or remote
        // refs that don't fit the tag/branch shapes above).
        let bare = try runGit(["ls-remote", url, ref])
        guard let line = bare.split(separator: "\n").first,
              let sha = line.split(separator: "\t").first,
              sha.count == 40 else {
            throw ThirdPartyError.sourceFetchFailed(reason: "git ls-remote returned no match for \(ref)")
        }
        return (sha: String(sha), tagName: nil)
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
