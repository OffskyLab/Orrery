import ArgumentParser

public struct AccountCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "account",
        abstract: L10n.Account.abstract,
        subcommands: [
            AccountAddCommand.self,
            AccountListCommand.self,
            AccountShowCommand.self,
            AccountUseCommand.self,
            AccountRemoveCommand.self,
        ]
    )

    public init() {}
}
