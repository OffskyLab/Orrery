import ArgumentParser
import Foundation

public struct UpdateCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: L10n.Update.abstract
    )

    @Flag(
        name: [.customLong("pre"), .customLong("rc")],
        help: ArgumentHelp(
            "Install the latest pre-release (RC) build instead of the latest stable release.")
    )
    public var pre: Bool = false

    public init() {}

    public func run() throws {
        print(L10n.Update.upgrading)

        #if os(macOS)
        let body = Self.shellBody(isMacOS: true, pre: pre)
        #elseif os(Linux)
        let body = Self.shellBody(isMacOS: false, pre: pre)
        #else
        print(L10n.Update.unsupportedPlatform)
        throw ExitCode.failure
        #endif

        let command = ["/bin/sh", "-c", body]
        let argv = command.map { strdup($0) } + [nil]
        execvp(command[0], argv)

        // execvp only returns on failure
        let errMsg = String(cString: strerror(errno))
        stderrWrite("orrery: update failed: \(errMsg)\n")
        throw ExitCode.failure
    }

    /// Build the `/bin/sh -c` body that performs the upgrade. Pure and testable.
    ///
    /// - macOS without `--pre`: prefer `brew upgrade` when orrery was installed
    ///   via Homebrew, else the curl install script (also handles in-place
    ///   upgrades).
    /// - `--pre` (any platform): always go through the install script with
    ///   `--pre-release`. The Homebrew tap ships only stable releases, so
    ///   pre-releases can only come from the install script (which resolves the
    ///   newest release including RCs).
    /// - Linux: always the install script.
    static func shellBody(isMacOS: Bool, pre: Bool) -> String {
        let installScriptCmd = "curl -fsSL https://offskylab.github.io/Orrery/install.sh | bash"
            + (pre ? " -s -- --pre-release" : "")
        let bookkeeping = #"rm -f "${ORRERY_HOME:-$HOME/.orrery}/.update-notice" && date +%s > "${ORRERY_HOME:-$HOME/.orrery}/.update-ts""#

        if isMacOS && !pre {
            return """
            if command -v brew >/dev/null 2>&1 && brew list orrery --versions >/dev/null 2>&1; then
              brew update && brew upgrade orrery
            else
              \(installScriptCmd)
            fi && \(bookkeeping)
            """
        }
        return "\(installScriptCmd) && \(bookkeeping)"
    }
}
