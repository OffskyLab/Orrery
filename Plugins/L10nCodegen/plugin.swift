import Foundation
import PackagePlugin

@main
struct L10nCodegenPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let target = target as? SourceModuleTarget, target.name == "OrreryCore" else {
            return []
        }

        let tool = try context.tool(named: "L10nCodegenTool")
        let output = context.pluginWorkDirectoryURL.appending(path: "L10n+Generated.swift")
        let resourcesDir = context.package.directoryURL.appending(path: "Sources/OrreryCore/Resources/Localization")
        let sig = resourcesDir.appending(path: "l10n-signatures.json")

        // Discover every `<locale>.json` next to the signatures file. English
        // is the authoritative base — it must come first in the argument list
        // so the codegen treats it as the schema reference. Adding a new locale
        // is just dropping a JSON in this directory + updating AppLocale +
        // Localizer's switch.
        let allFiles = (try? FileManager.default.contentsOfDirectory(at: resourcesDir, includingPropertiesForKeys: nil)) ?? []
        let localeFiles = allFiles
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "l10n-signatures.json" }
            .sorted { lhs, rhs in
                if lhs.lastPathComponent == "en.json" { return true }
                if rhs.lastPathComponent == "en.json" { return false }
                return lhs.lastPathComponent < rhs.lastPathComponent
            }

        let arguments = [output.path(), context.package.directoryURL.path()] + localeFiles.map { $0.path() }

        return [
            .buildCommand(
                displayName: "Generating L10n accessors",
                executable: tool.url,
                arguments: arguments,
                inputFiles: localeFiles + [sig],
                outputFiles: [output]
            )
        ]
    }
}
