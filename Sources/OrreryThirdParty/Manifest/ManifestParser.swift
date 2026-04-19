import Foundation
import OrreryCore

public enum ManifestParser {
    public static func parse(_ data: Data) throws -> ThirdPartyPackage {
        do {
            let file = try JSONDecoder().decode(ManifestFile.self, from: data)
            return file.toPackage()
        } catch {
            throw ThirdPartyError.packageNotFound(id: "(manifest parse failed: \(error))")
        }
    }
}
