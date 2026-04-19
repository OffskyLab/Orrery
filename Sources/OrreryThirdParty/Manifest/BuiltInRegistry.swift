import Foundation
import OrreryCore

public struct BuiltInRegistry: ThirdPartyRegistry {
    // Map of package id → manifest resource name (without .json). When more
    // add-ons ship, extend this table and add the matching Manifests/*.json.
    private static let table: [String: String] = [
        "cc-statusline": "cc-statusline",
    ]

    public init() {}

    public func lookup(_ id: String) throws -> ThirdPartyPackage {
        guard let resource = Self.table[id] else {
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
