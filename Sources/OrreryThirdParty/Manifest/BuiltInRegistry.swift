import Foundation
import OrreryCore

public struct BuiltInRegistry: ThirdPartyRegistry {
    // Manifests are embedded as string literals so the binary is self-contained
    // (no separate .bundle directory required after install).
    // When adding a new add-on: paste its JSON here and add an entry to `table`.
    private static let table: [String: String] = [
        "cc-statusline": ccStatuslineJSON,
    ]

    public init() {}

    public func lookup(_ id: String) throws -> ThirdPartyPackage {
        guard let json = Self.table[id],
              let data = json.data(using: .utf8) else {
            throw ThirdPartyError.packageNotFound(id: id)
        }
        return try ManifestParser.parse(data)
    }

    public func listAvailable() -> [String] {
        Array(Self.table.keys).sorted()
    }
}
