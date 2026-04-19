import Foundation
import OrreryCore

/// The runner calls this to get a local directory containing the source files
/// the steps will copy from. Implementations handle caching internally.
public protocol ThirdPartySourceFetcher: Sendable {
    /// Returns `(localDir, resolvedRef)`.
    func fetch(source: ThirdPartySource,
               cacheRoot: URL,
               packageID: String,
               refOverride: String?,
               forceRefresh: Bool) throws -> (URL, String)
}
