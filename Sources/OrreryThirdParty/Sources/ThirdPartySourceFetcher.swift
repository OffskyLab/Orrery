import Foundation
import OrreryCore

/// Result of resolving + fetching a package source.
public struct FetchedRef: Sendable, Equatable {
    /// Local directory containing the unpacked source the steps will copy from.
    public let dir: URL

    /// The underlying commit SHA. Stable across tag rewrites and used as the
    /// cache key, so every install pins reproducibly even when the symbolic
    /// ref (a branch HEAD, the meaning of `latest`) moves later.
    public let sha: String

    /// Human-readable label for the resolved ref — set when the install was
    /// pinned to a tag (so `latest` → `v0.2.7`, or `--ref v0.2.6` →
    /// `v0.2.6`), nil for branches and raw SHAs where the SHA is the only
    /// meaningful identifier. Surfaced via `InstallRecord.displayRef` and
    /// the `orrery install` success message.
    public let displayLabel: String?

    public init(dir: URL, sha: String, displayLabel: String?) {
        self.dir = dir
        self.sha = sha
        self.displayLabel = displayLabel
    }
}

/// The runner calls this to get a local directory containing the source files
/// the steps will copy from. Implementations handle caching internally.
public protocol ThirdPartySourceFetcher: Sendable {
    func fetch(source: ThirdPartySource,
               cacheRoot: URL,
               packageID: String,
               refOverride: String?,
               forceRefresh: Bool) throws -> FetchedRef
}
