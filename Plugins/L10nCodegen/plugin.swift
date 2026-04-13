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
        let en = context.package.directoryURL.appending(path: "Sources/OrreryCore/Resources/Localization/en.json")
        let zh = context.package.directoryURL.appending(path: "Sources/OrreryCore/Resources/Localization/zh-Hant.json")
        let sig = context.package.directoryURL.appending(path: "Sources/OrreryCore/Resources/Localization/l10n-signatures.json")

        return [
            .buildCommand(
                displayName: "Generating L10n accessors",
                executable: tool.url,
                arguments: [en.path(), zh.path(), output.path(), context.package.directoryURL.path()],
                inputFiles: [en, zh, sig],
                outputFiles: [output]
            )
        ]
    }
}
