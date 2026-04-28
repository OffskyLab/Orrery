import ArgumentParser
import Foundation

public struct SpecProfileResolver {

    public static func resolve(
        profileName: String?,
        store: EnvironmentStore
    ) throws -> SpecTemplate {
        let name = profileName ?? "default"

        // 1. Check built-in profiles
        if let builtin = BuiltinProfiles.find(named: name) {
            return builtin
        }

        // 2. Check project-level custom template (.orrery/templates/<name>.json)
        let projectTemplate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".orrery")
            .appendingPathComponent("templates")
            .appendingPathComponent("\(name).json")
        if FileManager.default.fileExists(atPath: projectTemplate.path) {
            let data = try Data(contentsOf: projectTemplate)
            return try JSONDecoder().decode(SpecTemplate.self, from: data)
        }

        // 3. Check global custom template (~/.orrery/templates/<name>.json)
        let globalTemplate = store.homeURL
            .appendingPathComponent("templates")
            .appendingPathComponent("\(name).json")
        if FileManager.default.fileExists(atPath: globalTemplate.path) {
            let data = try Data(contentsOf: globalTemplate)
            return try JSONDecoder().decode(SpecTemplate.self, from: data)
        }

        // 4. Not found
        throw ValidationError(L10n.Spec.profileNotFound(name))
    }
}
