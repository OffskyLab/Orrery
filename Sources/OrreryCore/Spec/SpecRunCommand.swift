import ArgumentParser
import Foundation

/// `orrery spec-run` — executes a spec's verify/implement/plan phase.
///
/// MVP (D15) only implements `verify`. Other modes throw
/// `modeNotImplemented` to avoid silent partial behaviour.
/// Output is always a single JSON object on stdout, even on validation
/// failure (see `SpecRunResult.errorShell`). Exit code is governed by
/// D12: verify is authoritative, review is advisory.
public struct SpecRunCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "spec-run",
        abstract: L10n.SpecRun.abstract
    )

    @Argument(help: ArgumentHelp(L10n.SpecRun.specPathHelp))
    public var specPath: String

    @Option(name: .long, help: ArgumentHelp(L10n.SpecRun.modeHelp))
    public var mode: String

    @Option(name: .long, help: ArgumentHelp(L10n.SpecRun.toolHelp))
    public var tool: String?

    @Option(name: .long, help: ArgumentHelp(L10n.SpecRun.resumeHelp))
    public var resumeSessionId: String?

    @Option(name: .long, help: ArgumentHelp(L10n.SpecRun.timeoutHelp))
    public var timeout: Int?

    @Option(name: .long, help: ArgumentHelp(L10n.SpecRun.perCommandTimeoutHelp))
    public var perCommandTimeout: Int?

    @Flag(name: .long, help: ArgumentHelp(L10n.SpecRun.executeHelp))
    public var execute: Bool = false

    @Flag(name: .long, help: ArgumentHelp(L10n.SpecRun.strictPolicyHelp))
    public var strictPolicy: Bool = false

    @Flag(name: .long, help: ArgumentHelp(L10n.SpecRun.reviewHelp))
    public var review: Bool = false

    @Option(name: .long, help: ArgumentHelp(L10n.SpecRun.sessionIdHelp))
    public var sessionId: String?

    @Flag(name: .long, help: ArgumentHelp(L10n.SpecRun.watchHelp))
    public var watch: Bool = false

    @Flag(name: .long, help: ArgumentHelp(L10n.SpecRun.includeLogHelp))
    public var includeLog: Bool = false

    @Option(name: .long, help: ArgumentHelp(L10n.SpecRun.sinceTimestampHelp))
    public var sinceTimestamp: String?

    @Option(name: .shortAndLong, help: ArgumentHelp(L10n.SpecRun.envHelp))
    public var environment: String?

    public init() {}

    public func run() throws {
        // --- Validate mode ----------------------------------------------
        let validModes: Set<String> = ["plan", "implement", "verify", "run", "status"]
        guard validModes.contains(mode) else {
            emitErrorJSON(phase: mode, error: L10n.SpecRun.invalidMode(mode))
            throw ValidationError(L10n.SpecRun.invalidMode(mode))
        }

        switch mode {
        case "verify":     try runVerify()
        case "implement":  try runImplement()
        case "status":     try runStatus()
        default:
            emitErrorJSON(phase: mode, error: L10n.SpecRun.modeNotImplemented(mode))
            throw ValidationError(L10n.SpecRun.modeNotImplemented(mode))
        }
    }

    // MARK: - Mode: verify

    private func runVerify() throws {
        let store = EnvironmentStore.default
        let envName = environment ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]

        let resolvedTool = try resolveOptionalTool(phase: "verify")

        let overallTimeoutSec = TimeInterval(timeout ?? Int(SpecSandboxPolicy.overallTimeoutDefault))
        let perCommandSec = TimeInterval(perCommandTimeout ?? Int(SpecSandboxPolicy.perCommandTimeoutDefault))

        let result: SpecRunResult
        do {
            result = try SpecVerifyRunner.run(
                specPath: specPath,
                tool: resolvedTool,
                environment: envName,
                store: store,
                execute: execute,
                strictPolicy: strictPolicy,
                perCommandTimeout: perCommandSec,
                overallTimeout: overallTimeoutSec,
                review: review,
                resumeSessionId: resumeSessionId
            )
        } catch let error as ValidationError {
            emitErrorJSON(phase: "verify", error: error.message)
            throw error
        } catch {
            emitErrorJSON(phase: "verify", error: "\(error)")
            throw error
        }

        let json = try result.toJSONString()
        print(json)
        if !result.stderr.isEmpty {
            FileHandle.standardError.write(Data((result.stderr + "\n").utf8))
        }

        let hasFail = result.verification.testResults.contains { $0.status == .fail }
        let hasBlocked = result.verification.testResults.contains { $0.status == .policyBlocked }
        let shouldFail = hasFail || (strictPolicy && hasBlocked)
        if shouldFail {
            throw ExitCode(1)
        }
    }

    // MARK: - Mode: implement

    private func runImplement() throws {
        let store = EnvironmentStore.default
        let envName = environment ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]

        let resolvedTool = try resolveOptionalTool(phase: "implement")

        // Default overall timeout for implement is 3600s (1h), per spec §2.
        let overallTimeoutSec = TimeInterval(timeout ?? 3600)

        let result: SpecRunResult
        do {
            result = try SpecImplementRunner.run(
                specPath: specPath,
                tool: resolvedTool,
                environment: envName,
                store: store,
                resumeSessionId: resumeSessionId,
                overallTimeout: overallTimeoutSec,
                tokenBudget: nil,
                watch: watch
            )
        } catch let error as ValidationError {
            emitErrorJSON(phase: "implement", error: error.message)
            throw error
        } catch {
            emitErrorJSON(phase: "implement", error: "\(error)")
            throw error
        }

        let json = try result.toJSONString()
        print(json)

        // Exit code policy:
        // - watch == false: early-return shape is always status="running"; exit 0
        // - watch == true: status ∈ {done, failed, aborted}; non-done → exit 1
        if watch && result.status != "done" {
            throw ExitCode(1)
        }
    }

    // MARK: - Mode: status

    private func runStatus() throws {
        guard let sid = sessionId else {
            emitErrorJSON(phase: "status", error: L10n.SpecRun.sessionIdRequired)
            throw ValidationError(L10n.SpecRun.sessionIdRequired)
        }

        let state: SpecRunState
        do {
            state = try SpecRunStateStore.load(sessionId: sid)
        } catch let error as ValidationError {
            emitErrorJSON(phase: "status", error: error.message)
            throw error
        } catch {
            emitErrorJSON(phase: "status", error: "\(error)")
            throw error
        }

        let logTail: [String]
        if includeLog {
            let path = SpecRunStateStore.progressLogPath(sessionId: sid).path
            logTail = (try? SpecProgressLog.tail(
                path: path,
                lines: 50,
                since: sinceTimestamp
            )) ?? []
        } else {
            logTail = []
        }

        let status = SpecStatusResult.from(state: state, logTail: logTail)
        let json = try status.toJSONString()
        print(json)

        // Status is a read-only query; exit 0 unless the underlying session
        // itself reports a terminal failure/abort.
        if state.status == "failed" {
            throw ExitCode(1)
        }
    }

    // MARK: - Shared helpers

    private func resolveOptionalTool(phase: String) throws -> Tool? {
        if let toolName = tool {
            guard let t = Tool(rawValue: toolName) else {
                emitErrorJSON(phase: phase, error: L10n.SpecRun.unknownTool(toolName))
                throw ValidationError(L10n.SpecRun.unknownTool(toolName))
            }
            return t
        }
        return nil
    }

    // MARK: - Helpers

    private func emitErrorJSON(phase: String, error: String) {
        let payload = SpecRunResult.errorShell(phase: phase, error: error)
        if let json = try? payload.toJSONString() {
            print(json)
        }
    }
}

// MARK: - ValidationError message bridge

private extension ValidationError {
    /// ArgumentParser's ValidationError doesn't expose its message publicly;
    /// we reconstruct via `String(describing:)` and trim the wrapper label.
    var message: String {
        let description = String(describing: self)
        // Formats observed: "ValidationError(message: \"...\")" or just "..."
        if let range = description.range(of: "message: \"") {
            let start = range.upperBound
            if let end = description.range(of: "\")", range: start..<description.endIndex)?.lowerBound {
                return String(description[start..<end])
            }
        }
        return description
    }
}
