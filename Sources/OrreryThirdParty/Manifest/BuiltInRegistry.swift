import Foundation
import OrreryCore

public struct BuiltInRegistry: ThirdPartyRegistry {
    // Map of package id → manifest resource name (without .json). When more
    // add-ons ship, extend this table and add the matching Manifests/*.json.
    // The `orrery-statusline` entry is kept as a back-compat alias so existing
    // lock files (written before the rename) can still be uninstalled.
    private static let table: [String: String] = [
        "statusline": "statusline",
    ]

    /// Legacy id → current id. Lookups still resolve so that lock files written
    /// under the old name can be uninstalled, but these never appear in
    /// `listAvailable()`.
    private static let aliases: [String: String] = [
        "orrery-statusline": "statusline",
    ]

    public init() {}

    public func lookup(_ id: String) throws -> ThirdPartyPackage {
        let resolved = Self.aliases[id] ?? id
        guard let resource = Self.table[resolved] else {
            throw ThirdPartyError.packageNotFound(id: id)
        }
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            throw ThirdPartyError.packageNotFound(id: id)
        }
        return try ManifestParser.parse(data)
    }

    public func listAvailable() -> [String] {
        Array(Self.table.keys).sorted()
    }
}
