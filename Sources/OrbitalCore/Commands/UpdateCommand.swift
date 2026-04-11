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
        let command = ["brew", "upgrade", "orbital"]
        #elseif os(Linux)
        let command = ["sudo", "apt-get", "install", "--only-upgrade", "-y", "orbital"]
        #else
        print(L10n.Update.unsupportedPlatform)
        throw ExitCode.failure
        #endif

        let argv = command.map { strdup($0) } + [nil]
        execvp(command[0], argv)

        // execvp only returns on failure
        let errMsg = String(cString: strerror(errno))
        FileHandle.standardError.write(Data("orbital: update failed: \(errMsg)\n".utf8))
        throw ExitCode.failure
    }
}
