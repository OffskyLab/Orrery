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

        #if os(macOS)
        let command = ["/bin/sh", "-c", "brew update && brew upgrade orrery && rm -f \"${ORRERY_HOME:-$HOME/.orrery}/.update-notice\" && date +%s > \"${ORRERY_HOME:-$HOME/.orrery}/.update-ts\""]
        #elseif os(Linux)
        let command = ["/bin/sh", "-c", "sudo apt-get install --only-upgrade -y orrery && rm -f \"${ORRERY_HOME:-$HOME/.orrery}/.update-notice\" && date +%s > \"${ORRERY_HOME:-$HOME/.orrery}/.update-ts\""]
        #else
        print(L10n.Update.unsupportedPlatform)
        throw ExitCode.failure
        #endif

        let argv = command.map { strdup($0) } + [nil]
        execvp(command[0], argv)

        // execvp only returns on failure
        let errMsg = String(cString: strerror(errno))
        stderrWrite("orrery: update failed: \(errMsg)\n")
        throw ExitCode.failure
    }
}
