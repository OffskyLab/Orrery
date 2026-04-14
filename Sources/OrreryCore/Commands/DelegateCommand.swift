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

    @Option(name: .long, help: ArgumentHelp(L10n.Delegate.sessionHelp))
    public var session: String?

    @Argument(help: ArgumentHelp(L10n.Delegate.promptHelp))
    public var prompt: String?

    public init() {}

    public func run() throws {
        let tool = resolvedTool()
        let envName = environment ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
        let store = EnvironmentStore.default

        // Validation
        if session != nil, resume != nil {
            throw ValidationError(L10n.Delegate.sessionResumeExclusive)
        }
        guard session != nil || resume != nil || prompt != nil else {
            throw ValidationError(L10n.Delegate.noPromptNoResume)
        }
        if session != nil, prompt == nil {
            throw ValidationError(L10n.Delegate.sessionRequiresPrompt)
        }

        // --- Managed session path: Claude/Gemini (native mapping) ---
        if let sessionName = session, tool != .codex, let userPrompt = prompt {
            try runNativeMappingPath(
                sessionName: sessionName, userPrompt: userPrompt,
                tool: tool, envName: envName, store: store)
            return
        }

        // --- Managed session path: Codex (fallback, text injection) ---
        if let sessionName = session, tool == .codex, let userPrompt = prompt {
            try runCodexFallbackPath(
                sessionName: sessionName, userPrompt: userPrompt,
                envName: envName, store: store)
            return
        }

        // --- Native resume path (existing) ---
        var sessionId: String?
        if let resumeValue = resume {
            let specifier = try SessionSpecifier(resumeValue)
            let cwd = FileManager.default.currentDirectoryPath
            let session = try SessionResolver.resolve(
                specifier, tool: tool, cwd: cwd, store: store, activeEnvironment: envName)
            sessionId = session.id
        }

        // --- One-shot / native resume path ---
        let builder = DelegateProcessBuilder(
            tool: tool,
            prompt: prompt,
            resumeSessionId: sessionId,
            environment: envName,
            store: store
        )
        let (process, _, _) = try builder.build()

        try process.run()
        process.waitUntilExit()

        throw ExitCode(process.terminationStatus)
    }

    // MARK: - Native mapping path (Claude/Gemini)

    private func runNativeMappingPath(
        sessionName: String, userPrompt: String,
        tool: Tool, envName: String?, store: EnvironmentStore
    ) throws {
        let mapping = SessionMapping(store: store)
        let cwd = FileManager.default.currentDirectoryPath
        let existing = mapping.load(name: sessionName, cwd: cwd)

        // If mapping exists and tool matches → native resume
        let resumeId: String?
        if let entry = existing, entry.tool == tool.rawValue {
            resumeId = entry.nativeSessionId
        } else {
            resumeId = nil
        }

        let builder = DelegateProcessBuilder(
            tool: tool,
            prompt: userPrompt,
            resumeSessionId: resumeId,
            environment: envName,
            store: store,
            captureStdout: false
        )
        let (process, _, _) = try builder.build()

        try process.run()
        process.waitUntilExit()

        // After delegate, find the latest native session ID and save mapping
        let sessions = SessionsCommand.findSessions(tool: tool, cwd: cwd, store: store)
            .sorted { ($0.lastTime ?? .distantPast) > ($1.lastTime ?? .distantPast) }
        if let latest = sessions.first {
            let entry = SessionMappingEntry(
                tool: tool.rawValue,
                nativeSessionId: latest.id,
                lastUsed: ISO8601DateFormatter().string(from: Date()))
            try? mapping.save(entry, name: sessionName, cwd: cwd)
        }

        throw ExitCode(process.terminationStatus)
    }

    // MARK: - Codex fallback path (text injection)

    private func runCodexFallbackPath(
        sessionName: String, userPrompt: String,
        envName: String?, store: EnvironmentStore
    ) throws {
        let mapping = SessionMapping(store: store)
        let cwd = FileManager.default.currentDirectoryPath

        // Load history and build combined prompt
        let turns = mapping.loadCodexTurns(name: sessionName, cwd: cwd)
        let combinedPrompt = SessionContextBuilder.buildPrompt(
            turns: turns, newPrompt: userPrompt, sessionName: sessionName)

        let builder = DelegateProcessBuilder(
            tool: .codex,
            prompt: combinedPrompt,
            resumeSessionId: nil,
            environment: envName,
            store: store,
            captureStdout: true
        )
        let (process, _, teeCapture) = try builder.build()

        try process.run()
        process.waitUntilExit()

        // Persist turns
        let now = ISO8601DateFormatter().string(from: Date())
        let userTurn = SessionTurn(
            role: "user", content: userPrompt,
            timestamp: now, tokenEstimate: userPrompt.count / 4)
        try? mapping.appendCodexTurn(userTurn, name: sessionName, cwd: cwd)

        if let capture = teeCapture {
            let response = capture.finish()
            if !response.isEmpty {
                let assistantTurn = SessionTurn(
                    role: "assistant", content: response,
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    tokenEstimate: response.count / 4)
                try? mapping.appendCodexTurn(assistantTurn, name: sessionName, cwd: cwd)
            }
        }

        // Save mapping (no native session ID for Codex)
        let entry = SessionMappingEntry(tool: "codex", nativeSessionId: nil, lastUsed: now)
        try? mapping.save(entry, name: sessionName, cwd: cwd)

        throw ExitCode(process.terminationStatus)
    }

    private func resolvedTool() -> Tool {
        if codex { return .codex }
        if gemini { return .gemini }
        return .claude
    }
}
