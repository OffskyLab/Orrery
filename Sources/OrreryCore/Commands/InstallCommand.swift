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
            claudeAccountLabel(forEnv: resolvedEnv),
            claudeWorkspaceLabel(forEnv: resolvedEnv)
        ))
    }
}

func installCurrentEnvOrThrow() throws -> String {
    let env = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
    // ORRERY_ACTIVE_ENV unset or "origin" → origin workspace
    return env ?? Workspace.reservedOriginName
}

/// Resolve the claude account dir add-ons install into / are removed from (the
/// account dir, not the workspace): the active `CLAUDE_CONFIG_DIR`, else the
/// claude account pinned to `env`. Nil when no account can be resolved.
func claudeAccountDirPath(forEnv env: String) -> String? {
    if let live = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !live.isEmpty {
        return live
    }
    let store = EnvironmentStore.default
    let pins = (env == Workspace.reservedOriginName)
        ? store.loadOriginWorkspace().accounts
        : ((try? store.load(named: env).accounts) ?? [:])
    return pins[Tool.claude.rawValue]
        .map { AccountStore.default.accountDir(id: $0, tool: .claude).path }
}

/// The resolved account's `metadata.json` as a dict, if readable.
private func claudeAccountMetadata(forEnv env: String) -> [String: Any]? {
    guard let dir = claudeAccountDirPath(forEnv: env),
          let data = try? Data(contentsOf: URL(fileURLWithPath: dir)
              .appendingPathComponent("metadata.json")),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return obj
}

/// Display name of the account add-ons install into. Falls back to the env name.
func claudeAccountLabel(forEnv env: String) -> String {
    claudeAccountMetadata(forEnv: env)?["displayName"] as? String ?? env
}

/// The workspace the target account is pinned to (`metadata.json` `workspace`,
/// absent ⇒ origin) — where the shared add-on files (e.g. the statusline
/// program) actually land.
func claudeWorkspaceLabel(forEnv env: String) -> String {
    guard let ws = claudeAccountMetadata(forEnv: env)?["workspace"] as? String,
          !ws.isEmpty
    else { return Workspace.reservedOriginName }
    return ws
}
