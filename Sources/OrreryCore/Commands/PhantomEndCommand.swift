import ArgumentParser
import Foundation

/// `orrery-bin _phantom-end --id <id>`
///
/// Called once the supervisor loop exits. Best-effort: a leftover entry is
/// harmless because liveness checks prune it, so this never reports failure.
public struct PhantomEndCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_phantom-end",
        shouldDisplay: false
    )

    @Option(name: .long) public var id: String

    public init() {}

    public func run() throws {
        PhantomRegistry(homeURL: EnvironmentStore.default.homeURL).remove(id: id)
    }
}
