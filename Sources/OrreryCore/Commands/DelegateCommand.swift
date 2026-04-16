import ArgumentParser
import Foundation

public struct DelegateCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "delegate",
        abstract: L10n.Delegate.abstract,
        discussion: "Example: orrery delegate --claude -e work \"check error handling\""
    )

    @Flag(help: ArgumentHelp(L10n.ToolFlag.claude))
    public var claude: Bool = false

    @Flag(help: ArgumentHelp(L10n.ToolFlag.codex))
    public var codex: Bool = false

    @Flag(help: ArgumentHelp(L10n.ToolFlag.gemini))
    public var gemini: Bool = false

    @Option(name: .shortAndLong, help: ArgumentHelp(L10n.Delegate.envHelp))
    public var environment: String?

    @Option(name: .long, help: ArgumentHelp(L10n.Delegate.resumeHelp))
    public var resume: String?

    @Flag(name: .long, help: ArgumentHelp(L10n.Delegate.sessionPickerHelp))
    public var session: Bool = false

    @Option(name: .long, help: ArgumentHelp(L10n.Delegate.sessionNameHelp))
    public var sessionName: String?

    @Argument(help: ArgumentHelp(L10n.Delegate.promptHelp))
    public var prompt: String?

    public init() {}

    public func run() throws {
        let store = EnvironmentStore.default
        let envName = environment ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
        let cwd = FileManager.default.currentDirectoryPath

        // Validation: --session / --session-name / --resume are mutually exclusive
        let sessionModes = [session, sessionName != nil, resume != nil].filter { $0 }.count
        if sessionModes > 1 {
            throw ValidationError(L10n.Delegate.sessionResumeExclusive)
        }

        // --- Picker mode: --session ---
        if session {
            let mapping = SessionMapping(store: store)
            let all = mapping.allMappings(cwd: cwd)
            let (name, entry) = try SessionPicker.pick(mappings: all, store: store, cwd: cwd)
            let tool = Tool(rawValue: entry.tool) ?? .claude

            // Picker mode: prompt can come from argument or interactive input
            let userPrompt: String
            if let p = prompt {
                userPrompt = p
            } else {
                print("Prompt: ", terminator: "")
                guard let line = readLine(), !line.isEmpty else {
                    throw ValidationError(L10n.Delegate.sessionRequiresPrompt)
                }
                userPrompt = line
            }

            try runNativeMappingPath(
                sessionName: name, userPrompt: userPrompt,
                tool: tool, envName: envName, store: store, cwd: cwd)
            return
        }

        // --- Named session mode: --session-name <name> ---
        if let sessionName = sessionName {
            guard let userPrompt = prompt else {
                throw ValidationError(L10n.Delegate.sessionRequiresPrompt)
            }
            let mapping = SessionMapping(store: store)
            let existing = mapping.load(name: sessionName, cwd: cwd)

            // Auto tool inference: use tool from mapping if available, else from flag
            let tool: Tool
            if let entry = existing, let t = Tool(rawValue: entry.tool) {
                tool = t
            } else {
                tool = resolvedTool()
            }

            try runNativeMappingPath(
                sessionName: sessionName, userPrompt: userPrompt,
                tool: tool, envName: envName, store: store, cwd: cwd)
            return
        }

        // --- Native resume path (existing) ---
        let tool = resolvedTool()
        guard resume != nil || prompt != nil else {
            throw ValidationError(L10n.Delegate.noPromptNoResume)
        }

        var sessionId: String?
        if let resumeValue = resume {
            let specifier = try SessionSpecifier(resumeValue)
            let session = try SessionResolver.resolve(
                specifier, tool: tool, cwd: cwd, store: store, activeEnvironment: envName)
            sessionId = session.id
        }

        let builder = DelegateProcessBuilder(
            tool: tool, prompt: prompt,
            resumeSessionId: sessionId,
            environment: envName, store: store)
        let (process, _, _) = try builder.build()
        try process.run()
        process.waitUntilExit()
        throw ExitCode(process.terminationStatus)
    }

    // MARK: - Unified native mapping path (all tools)

    private func runNativeMappingPath(
        sessionName: String, userPrompt: String,
        tool: Tool, envName: String?, store: EnvironmentStore, cwd: String
    ) throws {
        let mapping = SessionMapping(store: store)
        let existing = mapping.load(name: sessionName, cwd: cwd)

        let resumeId: String?
        if let entry = existing, entry.tool == tool.rawValue {
            resumeId = entry.nativeSessionId
        } else {
            resumeId = nil
        }

        let builder = DelegateProcessBuilder(
            tool: tool, prompt: userPrompt,
            resumeSessionId: resumeId,
            environment: envName, store: store)
        let (process, _, _) = try builder.build()

        try process.run()
        process.waitUntilExit()

        // Save/update mapping
        let sessions = SessionsCommand.findSessions(tool: tool, cwd: cwd, store: store)
            .sorted { ($0.lastTime ?? .distantPast) > ($1.lastTime ?? .distantPast) }
        if let latest = sessions.first {
            let entry = SessionMappingEntry(
                tool: tool.rawValue,
                nativeSessionId: latest.id,
                lastUsed: ISO8601DateFormatter().string(from: Date()),
                summary: String(latest.firstMessage.prefix(80)))
            try? mapping.save(entry, name: sessionName, cwd: cwd)
        }

        throw ExitCode(process.terminationStatus)
    }

    private func resolvedTool() -> Tool {
        if codex { return .codex }
        if gemini { return .gemini }
        return .claude
    }
}
