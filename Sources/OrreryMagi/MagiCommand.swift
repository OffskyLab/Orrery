import ArgumentParser
import Foundation
import OrreryCore

/// Thin shim over the `orrery-magi` sidecar binary. The Phase 2 Step 4
/// destructive cleanup removed all in-process orchestration; this
/// command exists only so `orrery --help` lists `magi` as a subcommand
/// and so `orrery magi …` round-trips through the sidecar.
///
/// In practice the executable's `main.swift` intercepts `magi` before
/// argument parsing reaches here (so unknown sidecar flags pass
/// through), but this `run()` is kept defensive in case that gate is
/// bypassed.
public struct MagiCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "magi",
        abstract: L10n.Magi.abstract
    )

    @Flag(help: ArgumentHelp(L10n.ToolFlag.claude))
    public var claude: Bool = false

    @Flag(help: ArgumentHelp(L10n.ToolFlag.codex))
    public var codex: Bool = false

    @Flag(help: ArgumentHelp(L10n.ToolFlag.gemini))
    public var gemini: Bool = false

    @Option(name: .shortAndLong, help: ArgumentHelp(L10n.Magi.envHelp))
    public var environment: String?

    @Option(name: .long, help: ArgumentHelp(L10n.Magi.roundsHelp))
    public var rounds: Int = 3

    @Option(name: .long, help: ArgumentHelp(L10n.Magi.outputHelp))
    public var output: String?

    @Option(name: .long, help: ArgumentHelp(L10n.Magi.resumeHelp))
    public var resume: String?

    @Option(name: .long, help: ArgumentHelp(L10n.Magi.rolesHelp))
    public var roles: String?

    @Flag(name: .long, help: ArgumentHelp(L10n.Magi.noSummarizeHelp))
    public var noSummarize: Bool = false

    @Flag(name: .long, help: ArgumentHelp(L10n.Magi.specHelp))
    public var spec: Bool = false

    @Argument(help: ArgumentHelp(L10n.Magi.topicHelp))
    public var topic: String

    public init() {}

    public func run() throws {
        let binary = try MagiSidecar.resolve()
        var argv: [String] = []
        if claude { argv.append("--claude") }
        if codex { argv.append("--codex") }
        if gemini { argv.append("--gemini") }
        if let environment { argv += ["-e", environment] }
        argv += ["--rounds", String(rounds)]
        if let output { argv += ["--output", output] }
        if let resume { argv += ["--resume", resume] }
        if let roles { argv += ["--roles", roles] }
        if noSummarize { argv.append("--no-summarize") }
        if spec { argv.append("--spec") }
        argv.append(topic)
        try MagiSidecar.dispatch(binary, args: argv)
    }
}
