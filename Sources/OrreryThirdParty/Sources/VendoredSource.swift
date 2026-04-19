import Foundation
import OrreryCore

/// Source fetcher that just points at an on-disk directory. Used by the
/// end-to-end test in task 20 to avoid a real network clone. Not wired into
/// the production runner path.
public struct VendoredSource: ThirdPartySourceFetcher {
    public init() {}

    func fetch(source: ThirdPartySource,
               cacheRoot: URL,
               packageID: String,
               refOverride: String?,
               forceRefresh: Bool) throws -> (URL, String) {
        guard case .vendored(let path) = source else {
            throw ThirdPartyError.sourceFetchFailed(reason: "VendoredSource only supports vendored source")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ThirdPartyError.sourceFetchFailed(reason: "vendored path not found: \(path)")
        }
        let sha = String(repeating: "0", count: 40)
        return (url, sha)
    }
}
