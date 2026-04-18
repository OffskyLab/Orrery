import ArgumentParser
import Foundation

public struct UpdateCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: L10n.Update.abstract
    )

    public init() {}

    public func run() throws {
        print(L10n.Update.upgrading)

        // On macOS, prefer `brew upgrade` when the user installed via Homebrew
        // (detected by `brew list orrery`). Otherwise fall back to the curl
        // install script, which also handles in-place upgrades.
        // On Linux, always use the install script.
        let installScriptCmd = "curl -fsSL https://offskylab.github.io/Orrery/install.sh | bash"
        let bookkeeping = #"rm -f "${ORRERY_HOME:-$HOME/.orrery}/.update-notice" && date +%s > "${ORRERY_HOME:-$HOME/.orrery}/.update-ts""#

        #if os(macOS)
        let shellBody = """
        if command -v brew >/dev/null 2>&1 && brew list orrery --versions >/dev/null 2>&1; then
          brew update && brew upgrade orrery
        else
          \(installScriptCmd)
        fi && \(bookkeeping)
        """
        #elseif os(Linux)
        let shellBody = "\(installScriptCmd) && \(bookkeeping)"
        #else
        print(L10n.Update.unsupportedPlatform)
        throw ExitCode.failure
        #endif

        let command = ["/bin/sh", "-c", shellBody]

        let argv = command.map { strdup($0) } + [nil]
        execvp(command[0], argv)

        // execvp only returns on failure
        let errMsg = String(cString: strerror(errno))
        stderrWrite("orrery: update failed: \(errMsg)\n")
        throw ExitCode.failure
    }
}
