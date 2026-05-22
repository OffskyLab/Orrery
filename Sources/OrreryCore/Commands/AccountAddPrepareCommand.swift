import ArgumentParser
import Foundation

/// Internal command: prepare an account-add login for Claude.
/// Invoked by the orrery shell function (not directly by users).
/// Writes the account to the store, creates a staging dir, writes a
/// `.orrery-prepare.json` metadata file, then prints the staging dir path
/// to stdout so the shell can capture it with `$(...)`.
public struct AccountAddPrepareCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_account-add-prepare",
        abstract: "Prepare an account-add login (internal; invoked by the orrery shell function for Claude).",
        shouldDisplay: false
    )

    @Flag(name: .long) public var claude: Bool = false
    @Flag(name: .long) public var codex: Bool = false
    @Flag(name: .long) public var gemini: Bool = false

    @Option(name: .long, help: ArgumentHelp(L10n.Account.addNameHelp))
    public var name: String?

    public init() {}

    public func run() throws {
        AddCommand.announceDefaultToolIfNoFlag(claude: claude, codex: codex, gemini: gemini)
        let tool = try AddCommand.resolveTool(claude: claude, codex: codex, gemini: gemini)
        let displayName = try resolveName()

        if try AccountStore.default.findByDisplayName(displayName, tool: tool) != nil {
            throw ValidationError(L10n.Account.addDuplicateName(displayName, tool.rawValue))
        }

        var account = Account(tool: tool, displayName: displayName)
        #if os(macOS)
        if tool == .claude {
            account.keychainItem = ClaudeKeychain.serviceName(forOrreryAccount: account.id)
        }
        #endif

        try AccountStore.default.save(account)

        // Create a staging directory in the system temp directory.
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        // Write the prepare metadata so _account-add-finalize can recover
        // accountID, tool, and displayName without re-passed flags.
        let metadata: [String: String] = [
            "accountID": account.id,
            "tool": tool.rawValue,
            "displayName": displayName,
        ]
        let metadataURL = stagingDir.appendingPathComponent(".orrery-prepare.json")
        let data = try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: metadataURL, options: .atomic)

        // Print only the staging dir path — the shell captures this with $(...).
        print(stagingDir.path)
    }

    private func resolveName() throws -> String {
        if let n = name, !n.isEmpty { return n }
        FileHandle.standardError.write(Data(L10n.Account.addNamePrompt.utf8))
        guard let input = readLine()?.trimmingCharacters(in: .whitespaces),
              !input.isEmpty
        else {
            FileHandle.standardError.write(Data((L10n.Account.addEmptyName + "\n").utf8))
            throw ValidationError(L10n.Account.addEmptyName)
        }
        return input
    }
}
