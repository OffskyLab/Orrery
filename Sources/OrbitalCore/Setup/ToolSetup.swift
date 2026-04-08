import Foundation

public struct ToolSetup {

    public enum SetupError: Error {
        case installFailed(String)
        case authFailed(String)
    }

    /// Run the full setup flow for a tool: check install → offer install → offer auth.
    /// Credentials are stored in configDir (the orbital env's tool subdirectory).
    public static func setup(_ tool: Tool, configDir: URL) throws {
        guard tool.supportsSetup else { return }

        print("")

        // ── 1. Check & install ──────────────────────────────────────────
        if !isInstalled(tool) {
            print("\(tool.rawValue) is not installed.")
            print("Install it now? [Y/n] ", terminator: "")
            fflush(stdout)
            let input = readLine()?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
            guard input.isEmpty || input == "y" || input == "yes" else {
                print("Skipping \(tool.rawValue) setup.\n")
                return
            }
            try install(tool)
        }

        // ── 2. Offer auth ───────────────────────────────────────────────
        print("Log in to \(tool.rawValue) now? [Y/n] ", terminator: "")
        fflush(stdout)
        let authInput = readLine()?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        guard authInput.isEmpty || authInput == "y" || authInput == "yes" else {
            if let cmd = tool.authCommand {
                print("Skipping login. Run '\(cmd.joined(separator: " "))' later.")
            }
            return
        }

        try authenticate(tool, configDir: configDir)
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

        enterAlternateScreen()
        print("Installing \(tool.rawValue) (\(cmd.joined(separator: " ")))...\n")
        fflush(stdout)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = cmd
        try process.run()
        process.waitUntilExit()

        exitAlternateScreen()

        guard process.terminationStatus == 0 else {
            throw SetupError.installFailed(tool.rawValue)
        }
        print("✓ \(tool.rawValue) installed")
    }

    static func authenticate(_ tool: Tool, configDir: URL) throws {
        guard let cmd = tool.authCommand else { return }

        print("Running: \(cmd.joined(separator: " "))")
        print("(credentials will be stored in: \(configDir.path))")
        fflush(stdout)

        var env = ProcessInfo.processInfo.environment
        env[tool.envVarName] = configDir.path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = cmd
        process.environment = env
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            print("✓ \(tool.rawValue) login complete")
        } else {
            print("⚠ \(tool.rawValue) login exited with code \(process.terminationStatus)")
            print("  You can retry later: \(cmd.joined(separator: " "))")
        }
    }

    // MARK: - Terminal helpers

    private static func enterAlternateScreen() {
        print("\u{1B}[?1049h", terminator: "")
        fflush(stdout)
    }

    private static func exitAlternateScreen() {
        print("\u{1B}[?1049l", terminator: "")
        fflush(stdout)
    }
}
