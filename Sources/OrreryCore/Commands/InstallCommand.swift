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
        // Show the tag name when one was resolved (`latest` → `v0.2.7`,
        // `--ref v0.2.6` → `v0.2.6`); fall back to a short SHA for branch
        // or raw-SHA installs.
        let display = record.displayRef ?? String(record.resolvedRef.prefix(7))
        let shortRef = "\(record.manifestRef)@\(display)"
        print(L10n.Install.success(
            record.packageID,
            shortRef,
            record.copiedFiles.count,
            claudeAccountLabel(forEnv: resolvedEnv)
        ))
    }
}

func installCurrentEnvOrThrow() throws -> String {
    let env = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
    // ORRERY_ACTIVE_ENV unset or "origin" → origin workspace
    return env ?? Workspace.reservedOriginName
}

/// The claude account add-ons are actually installed into / removed from (the
/// account dir, not the workspace). Resolves the active `CLAUDE_CONFIG_DIR`, else
/// the claude account pinned to `env`, and returns its display name. Falls back
/// to the env name when no account can be resolved.
func claudeAccountLabel(forEnv env: String) -> String {
    let configDir: String?
    if let live = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !live.isEmpty {
        configDir = live
    } else {
        let store = EnvironmentStore.default
        let pins = (env == Workspace.reservedOriginName)
            ? store.loadOriginWorkspace().accounts
            : ((try? store.load(named: env).accounts) ?? [:])
        configDir = pins[Tool.claude.rawValue]
            .map { AccountStore.default.accountDir(id: $0, tool: .claude).path }
    }
    guard let configDir,
          let data = try? Data(contentsOf: URL(fileURLWithPath: configDir)
              .appendingPathComponent("metadata.json")),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let name = obj["displayName"] as? String
    else { return env }
    return name
}
