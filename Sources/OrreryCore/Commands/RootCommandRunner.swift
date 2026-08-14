import ArgumentParser
import Foundation

/// Parses argv into the leaf subcommand that was actually invoked, runs it,
/// and reports errors against *that* command rather than the root.
///
/// `AsyncParsableCommand`'s default `main()` calls the top-level
/// `exit(withError:)`, which always builds its usage/help text against the
/// ROOT command type. That's correct for parse-time failures (unknown
/// subcommand, `--help`, a `validate()` throw) — the parser already attaches
/// the right command stack to those via `CommandError`. But a
/// `ValidationError` thrown from inside a subcommand's `run()` (this
/// codebase's convention for "bad input" — see e.g. `RefreshTokenCommand`)
/// isn't wrapped that way, so it fell through to the root's usage: running
/// `orrery refresh-token` with no account name printed "Usage: orrery
/// <subcommand> / See 'orrery --help'" instead of `refresh-token`'s own
/// usage. This walks the (public) subcommand tree to find the leaf that was
/// actually parsed and reports the error against it instead.
public func runRootCommandReportingLeafErrors<Root: AsyncParsableCommand>(
    _ root: Root.Type
) async throws {
    var leaf: ParsableCommand.Type = root
    do {
        var command = try Root.parseAsRoot()
        leaf = type(of: command)
        if var asyncCommand = command as? AsyncParsableCommand {
            try await asyncCommand.run()
        } else {
            try command.run()
        }
    } catch let error as ValidationError {
        reportLeafValidationError(error, root: root, leaf: leaf)
    } catch {
        Root.exit(withError: error)
    }
}

private func reportLeafValidationError<Root: ParsableCommand>(
    _ error: ValidationError, root: Root.Type, leaf: ParsableCommand.Type
) -> Never {
    stderrWrite("Error: \(error.message)\n")
    let usage = root.usageString(for: leaf)
    if !usage.isEmpty {
        stderrWrite("Usage: \(usage)\n")
    }
    if let path = commandNamePath(to: leaf, from: root) {
        stderrWrite("  See '\(path.joined(separator: " ")) --help' for more information.\n")
    }
    Foundation.exit(ExitCode.validationFailure.rawValue)
}

private func commandNamePath(
    to leaf: ParsableCommand.Type, from node: ParsableCommand.Type
) -> [String]? {
    if ObjectIdentifier(node) == ObjectIdentifier(leaf) {
        return [node._commandName]
    }
    for child in node.configuration.subcommands {
        if let rest = commandNamePath(to: leaf, from: child) {
            return [node._commandName] + rest
        }
    }
    return nil
}
