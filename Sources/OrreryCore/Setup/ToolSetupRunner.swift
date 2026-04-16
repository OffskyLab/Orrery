import Foundation

/// Drives the per-tool setup flow (login copy → clone → sessions → memory) used by
/// both `orrery create` and `orrery tools add`. Keeps create/tools thin.
public enum ToolSetupRunner {

    public struct Config {
        public let tool: Tool
        public let loginSource: String?   // nil = independent (no copy)
        public let cloneSource: String?   // nil = don't clone settings
        public let isolateSessions: Bool  // per-tool
        public let isolateMemory: Bool?   // nil if tool doesn't support memory isolation

        public init(
            tool: Tool,
            loginSource: String?,
            cloneSource: String?,
            isolateSessions: Bool,
            isolateMemory: Bool?
        ) {
            self.tool = tool
            self.loginSource = loginSource
            self.cloneSource = cloneSource
            self.isolateSessions = isolateSessions
            self.isolateMemory = isolateMemory
        }
    }

    // MARK: - Wizard

    /// Run the per-tool wizard (login → clone → sessions → memory).
    /// Caller is responsible for asking the y/n "setup this tool?" gate before calling.
    ///
    /// Optional override args let CLI flags pre-fill specific steps; when an override
    /// is provided, the corresponding wizard step is skipped. `nil` for the
    /// `String?` overrides means "ask the wizard". Bool overrides only skip the
    /// wizard when `true`; `false` falls through to the wizard (since the flag
    /// is opt-in: absent flag is indistinguishable from explicit `false`).
    public static func runWizard(
        for tool: Tool,
        store: EnvironmentStore,
        loginSourceOverride: String? = nil,
        cloneSourceOverride: String? = nil,
        isolateSessionsOverride: Bool = false,
        isolateMemoryOverride: Bool = false
    ) -> Config {
        let loginSource = loginSourceOverride ?? askLoginCopySource(tool: tool, store: store)
        let cloneSource = cloneSourceOverride ?? askCloneSource(tool: tool, store: store)
        let isolateSessions = isolateSessionsOverride ? true : askSessionIsolation(tool: tool)
        let isolateMemory: Bool? = tool.flowType.supportsMemoryIsolation
            ? (isolateMemoryOverride ? true : askMemoryIsolation())
            : nil
        return Config(
            tool: tool,
            loginSource: loginSource,
            cloneSource: cloneSource,
            isolateSessions: isolateSessions,
            isolateMemory: isolateMemory
        )
    }

    // MARK: - Apply

    /// Apply a gathered config to an env: update per-tool flags, add tool,
    /// copy login state, copy non-login settings.
    public static func apply(_ config: Config, to envName: String, store: EnvironmentStore) throws {
        // Update env's per-tool flags so addTool picks up the right session behavior.
        var env = try store.load(named: envName)
        if config.isolateSessions {
            env.isolatedSessionTools.insert(config.tool)
        } else {
            env.isolatedSessionTools.remove(config.tool)
        }
        if let memIso = config.isolateMemory {
            env.isolateMemory = memIso
        }
        try store.save(env)

        // Install tool if missing
        let targetDir = store.toolConfigDir(tool: config.tool, environment: envName)
        try ToolSetup.setup(config.tool, configDir: targetDir, envName: envName)

        // Add to env (creates config dir + session symlinks per env's updated flags)
        try store.addTool(config.tool, to: envName)

        // Link the Orrery memory directory into Claude's auto-memory location
        if config.tool == .claude {
            let projectKey = FileManager.default.currentDirectoryPath
                .replacingOccurrences(of: "/", with: "-")
            store.linkOrreryMemory(
                projectKey: projectKey,
                envName: envName,
                claudeConfigDir: targetDir
            )
        }

        // Order matters for Claude: copy non-login settings FIRST (brings the clone source's
        // `.claude.json` containing theme/prefs), then login copy merges identity keys into it.
        if let cloneSource = config.cloneSource {
            let sourceDir = cloneSourceDir(for: cloneSource, tool: config.tool, store: store)
            config.tool.flowType.copyNonLoginSettings(sourceDir: sourceDir, targetDir: targetDir)
            print(L10n.Create.cloned(cloneSource))
        }

        if let loginSource = config.loginSource {
            let sourceDir = loginSourceDir(for: loginSource, tool: config.tool, store: store)
            if config.tool.flowType.copyLoginState(sourceDir: sourceDir, targetDir: targetDir) {
                print(L10n.Create.copyLoginCopied(loginSource))
            } else {
                print(L10n.Create.copyLoginFailed(loginSource))
            }
        } else if config.tool == .claude {
            // User chose "I'll log in myself". If a clone brought over X's .claude.json,
            // strip X's identity + onboarding markers so Claude runs its own onboarding
            // + login at next launch (instead of silently adopting X's account).
            ClaudeFlow.prepareForSelfLogin(targetDir: targetDir)
        }
    }

    // MARK: - Wizard internals

    /// Login copy options are keyed by ACCOUNT (email), not by env — the credential for
    /// the same account in two envs is the same thing. We pick any env as the copy source
    /// per unique account. Envs without login info don't appear.
    ///
    /// Speed: during iteration we do a fast `.claude.json` email read first, and skip
    /// the full (Keychain-touching) `accountInfo` lookup entirely if the email is already
    /// known — so N duplicate-account envs don't trigger N slow Keychain subprocesses.
    static func askLoginCopySource(tool: Tool, store: EnvironmentStore) -> String? {
        let defaultName = ReservedEnvironment.defaultName

        // Yellow loading indicator, erased after queries are done.
        let loading = "\u{1B}[1;33m\(L10n.Create.queryingLoginStatus)\u{1B}[0m"
        stdoutWrite(loading)

        var seenEmails = Set<String>()
        var unique: [(source: String, info: ToolAuth.AccountInfo)] = []

        func tryAdd(source: String, configDir: URL?) {
            // Fast path: skip this env if its email is already known.
            if let email = ToolAuth.quickEmail(tool: tool, configDir: configDir),
               seenEmails.contains(email) {
                return
            }
            let info = ToolAuth.accountInfo(tool: tool, configDir: configDir)
            guard !info.isEmpty else { return }
            if let email = info.email {
                guard seenEmails.insert(email).inserted else { return }
            }
            unique.append((source, info))
        }

        // Origin first — wins ties so "from origin" is preferred for shared accounts.
        tryAdd(source: defaultName, configDir: nil)

        if let names = try? store.listNames() {
            for envName in names.sorted() {
                guard let env = try? store.load(named: envName), env.tools.contains(tool) else { continue }
                tryAdd(source: envName, configDir: store.toolConfigDir(tool: tool, environment: envName))
            }
        }

        // Clear loading line before showing the wizard.
        stdoutWrite("\r\u{1B}[2K")

        var options = [L10n.Create.copyLoginIndependent]
        var sources: [String?] = [nil]
        for (src, info) in unique {
            let label = [info.email, info.plan].compactMap { $0 }.joined(separator: " · ")
            options.append(L10n.Create.copyLoginFrom(label))
            sources.append(src)
        }

        let selector = SingleSelect(
            title: L10n.Create.copyLoginPromptFor(tool.rawValue),
            options: options,
            selected: 0
        )
        return sources[selector.run()]
    }

    static func askCloneSource(tool: Tool, store: EnvironmentStore) -> String? {
        let defaultName = ReservedEnvironment.defaultName
        var options = [L10n.Create.cloneNone]
        var sources: [String?] = [nil]

        options.append(L10n.Create.cloneFrom("\(defaultName) - \(L10n.Create.defaultDescription)"))
        sources.append(defaultName)

        if let names = try? store.listNames() {
            for envName in names.sorted() {
                guard let env = try? store.load(named: envName), env.tools.contains(tool) else { continue }
                let label = env.description.isEmpty ? envName : "\(envName) - \(env.description)"
                options.append(L10n.Create.cloneFrom(label))
                sources.append(envName)
            }
        }

        let selector = SingleSelect(
            title: L10n.Create.clonePromptFor(tool.rawValue),
            options: options,
            selected: 0
        )
        return sources[selector.run()]
    }

    static func askSessionIsolation(tool: Tool) -> Bool {
        let selector = SingleSelect(
            title: L10n.Create.sessionSharePromptFor(tool.rawValue),
            options: [L10n.Create.sessionShareYes, L10n.Create.sessionShareNo],
            selected: 0
        )
        return selector.run() == 1
    }

    static func askMemoryIsolation() -> Bool {
        let selector = SingleSelect(
            title: L10n.Create.memorySharePrompt,
            options: [L10n.Create.memoryShareYes, L10n.Create.memoryShareNo],
            selected: 1
        )
        return selector.run() == 1
    }

    // MARK: - Source URL resolution

    /// For login copy: origin → nil (flow handles origin specially), else the env's tool config dir.
    private static func loginSourceDir(for source: String, tool: Tool, store: EnvironmentStore) -> URL? {
        source == ReservedEnvironment.defaultName
            ? nil
            : store.toolConfigDir(tool: tool, environment: source)
    }

    /// For clone: origin → tool's default config dir, else the env's tool config dir.
    private static func cloneSourceDir(for source: String, tool: Tool, store: EnvironmentStore) -> URL {
        source == ReservedEnvironment.defaultName
            ? tool.defaultConfigDir
            : store.toolConfigDir(tool: tool, environment: source)
    }
}
