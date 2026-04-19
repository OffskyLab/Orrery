import Foundation
import OrreryCore

/// On-disk representation of a manifest. Kept separate from
/// `ThirdPartyPackage` so the file schema can evolve (new fields, deprecations)
/// without changing the runtime type used everywhere else.
struct ManifestFile: Decodable {
    let id: String
    let displayName: String
    let description: String
    let source: ThirdPartySource
    let steps: [ThirdPartyStep]
}

extension ManifestFile {
    func toPackage() -> ThirdPartyPackage {
        ThirdPartyPackage(
            id: id,
            displayName: displayName,
            description: description,
            source: source,
            steps: steps
        )
    }
}
