import ArgumentParser
import Foundation
import OrreryCore

public enum MagiSidecarError: Error, CustomStringConvertible {
    case binaryNotFound
    case capabilitiesFailed(stderr: String)
    case capabilitiesInvalidJSON
    case schemaVersionUnsupported(found: Int, max: Int)
    case shimProtocolIncompatible(found: Int, required: Int)
    case mcpSchemaFetchFailed

    public var description: String {
        switch self {
        case .binaryNotFound:
            return "orrery-magi binary not found (checked ORRERY_MAGI_PATH, ~/.orrery/bin, PATH). Install with: brew install offskylab/orrery/orrery-magi"
        case .capabilitiesFailed(let stderr):
            return "orrery-magi --capabilities failed: \(stderr)"
        case .capabilitiesInvalidJSON:
            return "orrery-magi --capabilities did not produce valid JSON."
        case .schemaVersionUnsupported(let found, let max):
            return "orrery-magi capabilities $schema_version=\(found) > shim max=\(max). Upgrade orrery."
        case .shimProtocolIncompatible(let found, let required):
            return "orrery-magi compatibility.shim_protocol=\(found) < shim required=\(required). Upgrade orrery-magi."
        case .mcpSchemaFetchFailed:
            return "orrery-magi MCP schema fetch failed."
        }
    }
}

/// Detects + delegates to an external `orrery-magi` binary. Phase 2
/// Step 4 removed the in-process fallback: `resolve()` now always
/// throws `MagiSidecarError` if the sidecar is missing or its
/// capabilities handshake fails. Install the sidecar via
/// `brew install offskylab/orrery/orrery-magi` (or place a binary at
/// `~/.orrery/bin/orrery-magi` / on `PATH` / via `ORRERY_MAGI_PATH`).
public enum MagiSidecar {

    public struct ResolvedBinary {
        public let path: String
        public let version: String
        public let mcpSchemas: [[String: Any]]
        public let multiToolSchemaStable: Bool
        public let specRuntimeStable: Bool

        public init(
            path: String,
            version: String,
            mcpSchemas: [[String: Any]],
            multiToolSchemaStable: Bool,
            specRuntimeStable: Bool
        ) {
            self.path = path
            self.version = version
            self.mcpSchemas = mcpSchemas
            self.multiToolSchemaStable = multiToolSchemaStable
            self.specRuntimeStable = specRuntimeStable
        }
    }

    public struct SpawnResult {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
        public let timedOut: Bool

        public init(stdout: String, stderr: String, exitCode: Int32, timedOut: Bool) {
            self.stdout = stdout
            self.stderr = stderr
            self.exitCode = exitCode
            self.timedOut = timedOut
        }
    }

    /// The shim's max-supported capabilities `$schema_version`.
    public static let maxSchemaVersion: Int = 1

    /// The shim's argv-construction protocol version.
    public static let shimProtocolVersion: Int = 1

    /// Resolve the sidecar binary and validate its capabilities.
    /// Throws `MagiSidecarError` if the binary is missing, the
    /// handshake fails, or its protocol versions fall outside the
    /// shim's supported range.
    public static func resolve() throws -> ResolvedBinary {
        try resolveInternal()
    }

    /// Spawn the binary with the user's argv, wired through stdio,
    /// and propagate the exit code. Throws ExitCode of the subprocess.
    public static func dispatch(_ binary: ResolvedBinary, args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary.path)
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            throw MagiSidecarError.capabilitiesFailed(
                stderr: "Failed to spawn orrery-magi: \(error.localizedDescription)")
        }

        process.waitUntilExit()
        let status = process.terminationStatus
        if status == 0 { return }
        throw ExitCode(status)
    }

    /// Spawn the binary with the given args and capture stdout/stderr
    /// concurrently using async Tasks. Used for large output (tool forwarding).
    public static func spawnAndCapture(
        binary: String,
        args: [String],
        timeout: TimeInterval
    ) async -> SpawnResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutTask = Task.detached {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrTask = Task.detached {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                process.terminate()
                try? stdoutPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForReading.close()
            } catch { /* cancelled */ }
        }

        do {
            try process.run()
        } catch {
            timeoutTask.cancel()
            stdoutTask.cancel()
            stderrTask.cancel()
            return SpawnResult(stdout: "", stderr: "spawn failed: \(error.localizedDescription)",
                               exitCode: -1, timedOut: false)
        }

        process.waitUntilExit()
        timeoutTask.cancel()

        let stdoutData = await stdoutTask.value
        let stderrData = await stderrTask.value

        let timedOut = process.terminationReason == .uncaughtSignal && process.terminationStatus == 15
        return SpawnResult(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus,
            timedOut: timedOut
        )
    }

    /// Spawn the binary synchronously with sequential pipe reads after waitUntilExit.
    /// Safe for small output (--capabilities / --print-mcp-schemas << 64 KB pipe buffer).
    private static func spawnSmall(
        binary: String,
        args: [String],
        timeout: TimeInterval
    ) -> SpawnResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let timeoutWork = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        do {
            try process.run()
        } catch {
            timeoutWork.cancel()
            return SpawnResult(stdout: "", stderr: "spawn failed: \(error.localizedDescription)",
                               exitCode: -1, timedOut: false)
        }

        process.waitUntilExit()
        timeoutWork.cancel()

        // Sequential reads safe: --capabilities / --print-mcp-schemas output << 64 KB pipe buffer.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let timedOut = process.terminationReason == .uncaughtSignal && process.terminationStatus == 15
        return SpawnResult(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus,
            timedOut: timedOut
        )
    }

    // MARK: - Private

    private static func resolveInternal() throws -> ResolvedBinary {
        guard let path = findBinary() else {
            throw MagiSidecarError.binaryNotFound
        }

        let caps = try capabilities(path: path)

        let schemaVersion = caps["$schema_version"] as? Int ?? -1
        guard schemaVersion <= maxSchemaVersion, schemaVersion >= 0 else {
            throw MagiSidecarError.schemaVersionUnsupported(
                found: schemaVersion,
                max: maxSchemaVersion
            )
        }

        let compatibility = caps["compatibility"] as? [String: Any]
        let protocolVersion = compatibility?["shim_protocol"] as? Int ?? -1
        guard protocolVersion >= shimProtocolVersion else {
            throw MagiSidecarError.shimProtocolIncompatible(
                found: protocolVersion,
                required: shimProtocolVersion
            )
        }

        let features = caps["features"] as? [String: Any] ?? [:]
        let multiToolSchemaStable =
            ((features["multi_tool_schema"] as? [String: Any])?["status"] as? String) == "stable"
        let specRuntimeStable =
            ((features["spec_runtime"] as? [String: Any])?["status"] as? String) == "stable"

        let tool = caps["tool"] as? [String: Any] ?? [:]
        let version = tool["version"] as? String ?? "?"

        let mcpSchemas: [[String: Any]]
        if multiToolSchemaStable {
            switch runJSONArray(path: path, args: ["--print-mcp-schemas"], timeout: 5) {
            case .success(let schemas):
                mcpSchemas = schemas
            case .failure:
                throw MagiSidecarError.mcpSchemaFetchFailed
            }
        } else {
            switch runJSON(path: path, args: ["--print-mcp-schema"], timeout: 5) {
            case .success(let schema):
                mcpSchemas = [schema]
            case .failure:
                throw MagiSidecarError.mcpSchemaFetchFailed
            }
        }

        return ResolvedBinary(
            path: path,
            version: version,
            mcpSchemas: mcpSchemas,
            multiToolSchemaStable: multiToolSchemaStable,
            specRuntimeStable: specRuntimeStable
        )
    }

    private static func findBinary() -> String? {
        let fileManager = FileManager.default

        if let path = ProcessInfo.processInfo.environment["ORRERY_MAGI_PATH"],
           fileManager.isExecutableFile(atPath: path) {
            return path
        }

        let home: String
        if let custom = ProcessInfo.processInfo.environment["ORRERY_HOME"] {
            home = custom
        } else {
            home = fileManager.homeDirectoryForCurrentUser.path + "/.orrery"
        }

        let localPath = home + "/bin/orrery-magi"
        if fileManager.isExecutableFile(atPath: localPath) {
            return localPath
        }

        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["orrery-magi"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        try? which.run()
        which.waitUntilExit()

        if which.terminationStatus == 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let path = output, !path.isEmpty {
                return path
            }
        }

        return nil
    }

    static func runJSON(path: String, args: [String], timeout: TimeInterval) -> Result<[String: Any], MagiSidecarError> {
        let result = spawnSmall(binary: path, args: args, timeout: timeout)
        let trimmedStderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = trimmedStderr.isEmpty ? "unknown error" : trimmedStderr

        if result.timedOut {
            return .failure(.capabilitiesFailed(stderr: "timed out after \(Int(timeout))s"))
        }

        guard result.exitCode == 0 else {
            return .failure(.capabilitiesFailed(stderr: stderr))
        }

        guard let data = result.stdout.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.capabilitiesInvalidJSON)
        }

        return .success(json)
    }

    static func runJSONArray(
        path: String,
        args: [String],
        timeout: TimeInterval
    ) -> Result<[[String: Any]], MagiSidecarError> {
        let result = spawnSmall(binary: path, args: args, timeout: timeout)
        let trimmedStderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = trimmedStderr.isEmpty ? "unknown error" : trimmedStderr

        if result.timedOut {
            return .failure(.capabilitiesFailed(stderr: "timed out after \(Int(timeout))s"))
        }

        guard result.exitCode == 0 else {
            return .failure(.capabilitiesFailed(stderr: stderr))
        }

        guard let data = result.stdout.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return .failure(.capabilitiesInvalidJSON)
        }

        return .success(json)
    }

    private static func capabilities(path: String) throws -> [String: Any] {
        switch runJSON(path: path, args: ["--capabilities"], timeout: 5) {
        case .success(let caps):
            return caps
        case .failure(let error):
            throw error
        }
    }
}
