import Foundation

public struct ToolSetup {

    public enum SetupError: Error {
        case installFailed(String)
    }

    /// Run the full setup flow for a tool: check install → offer install.
    public static func setup(_ tool: Tool, configDir: URL, envName: String) throws {
        guard tool.supportsSetup else { return }

        print("")

        if !isInstalled(tool) {
            print(L10n.ToolSetup.notInstalled(tool.rawValue))
            FileHandle.standardOutput.write(Data(L10n.ToolSetup.installNow.utf8))
            let input = readLine()?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
            guard input.isEmpty || input == "y" || input == "yes" else {
                print(L10n.ToolSetup.skipping(tool.rawValue))
                return
            }
            try install(tool)
        }
    }

    /// Ask about login for each tool, then execvp into a shell to run them all.
    /// Call this as the last step in a command — it replaces the current process.
    public static func execLoginIfNeeded(tools: [Tool], store: EnvironmentStore, envName: String) {
        var loginCommands: [String] = []
        for t in tools {
            guard let authCmd = t.authLoginCommand else { continue }
            print("")
            FileHandle.standardOutput.write(Data(L10n.ToolSetup.loginNow(t.rawValue).utf8))
            let input = readLine()?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
            guard input.isEmpty || input == "y" || input == "yes" else {
                print(L10n.ToolSetup.skippingLogin(t.rawValue))
                continue
            }
            let configDir = store.toolConfigDir(tool: t, environment: envName)
            let cmd = authCmd.joined(separator: " ")
            loginCommands.append("\(t.envVarName)=\(configDir.path.shellEscaped) \(cmd)")
        }

        guard !loginCommands.isEmpty else { return }

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        env.removeValue(forKey: "CLAUDE_CODE_EXECPATH")
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        for (key, value) in env { setenv(key, value, 1) }

        let shellCmd = loginCommands.joined(separator: "; ")
        let shellArgs: [String] = ["/bin/sh", "-c", shellCmd]
        let argv = shellArgs.map { strdup($0) } + [nil]
        execvp(shellArgs[0], argv)
        perror("execvp")
    }

    // MARK: - Internal

    static func isInstalled(_ tool: Tool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [tool.rawValue]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func install(_ tool: Tool) throws {
        guard let cmd = tool.installCommand else { return }

        FileHandle.standardOutput.write(Data("\u{1B}[?1049h".utf8))
        print(L10n.ToolSetup.installing(tool.rawValue, cmd.joined(separator: " ")))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = cmd
        try process.run()
        process.waitUntilExit()

        FileHandle.standardOutput.write(Data("\u{1B}[?1049l".utf8))

        guard process.terminationStatus == 0 else {
            throw SetupError.installFailed(tool.rawValue)
        }
        print(L10n.ToolSetup.installed(tool.rawValue))
    }
}

private extension String {
    var shellEscaped: String { "'\(replacingOccurrences(of: "'", with: "'\\''"))'" }
}
