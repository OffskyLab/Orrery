import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct ToolSetup {

    public enum SetupError: Error {
        case installFailed(String)
        case authFailed(String)
    }

    /// Run the full setup flow for a tool: check install → offer install.
    public static func setup(_ tool: Tool, configDir: URL, envName: String) throws {
        guard tool.supportsSetup else { return }

        print("")

        if !isInstalled(tool) {
            print(L10n.ToolSetup.notInstalled(tool.rawValue))
            print(L10n.ToolSetup.installNow, terminator: "")
            fflush(stdout)
            let input = readLine()?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
            guard input.isEmpty || input == "y" || input == "yes" else {
                print(L10n.ToolSetup.skipping(tool.rawValue))
                return
            }
            try install(tool)
        }
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
        print(L10n.ToolSetup.installing(tool.rawValue, cmd.joined(separator: " ")))
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
        print(L10n.ToolSetup.installed(tool.rawValue))
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
