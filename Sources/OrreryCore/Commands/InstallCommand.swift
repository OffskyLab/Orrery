import ArgumentParser
import Foundation

public struct InstallCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: L10n.Install.abstract
    )

    @Argument(help: ArgumentHelp(L10n.Install.idHelp))
    public var id: String

    @Option(name: .long, help: ArgumentHelp(L10n.Install.envHelp))
    public var env: String?

    @Option(name: .long, help: ArgumentHelp(L10n.Install.urlHelp))
    public var url: String?

    @Option(name: .long, help: ArgumentHelp(L10n.Install.refHelp))
    public var ref: String?

    @Flag(name: .long, help: ArgumentHelp(L10n.Install.forceRefreshHelp))
    public var forceRefresh: Bool = false

    public init() {}

    public func run() throws {
        let resolvedEnv = try env ?? installCurrentEnvOrThrow()
        let registry = try ThirdPartyRuntime.registry()
        let runner = try ThirdPartyRuntime.runner()
        var pkg = try registry.lookup(id)
        if let url {
            pkg = pkg.replacingGitURL(url)
        }
        let record = try runner.install(pkg, into: resolvedEnv,
                                        refOverride: ref, forceRefresh: forceRefresh)
        let shortRef = "\(record.manifestRef)@\(record.resolvedRef.prefix(7))"
        print(L10n.Install.success(
            record.packageID,
            shortRef,
            record.copiedFiles.count,
            resolvedEnv
        ))
    }
}

func installCurrentEnvOrThrow() throws -> String {
    guard let env = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"] else {
        throw ValidationError("No active environment. Use --env <env> or switch with `orrery use <env>`.")
    }
    return env
}
