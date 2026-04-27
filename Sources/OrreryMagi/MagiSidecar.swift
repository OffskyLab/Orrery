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
            return "orrery-magi binary not found (checked ORRERY_MAGI_PATH, ~/.orrery/bin, PATH). ORRERY_MAGI_STRICT requires the sidecar to be installed."
        case .capabilitiesFailed(let stderr):
            return "orrery-magi --capabilities failed: \(stderr)"
        case .capabilitiesInvalidJSON:
            return "orrery-magi --capabilities did not produce valid JSON."
        case .schemaVersionUnsupported(let found, let max):
            return "orrery-magi capabilities $schema_version=\(found) > shim max=\(max). Upgrade orrery."
        case .shimProtocolIncompatible(let found, let required):
            return "orrery-magi compatibility.shim_protocol=\(found) < shim required=\(required). Upgrade orrery-magi."
        case .mcpSchemaFetchFailed:
            return "orrery-magi --print-mcp-schema failed. ORRERY_MAGI_STRICT requires this to succeed."
        }
    }
}

/// Detects + delegates to an external `orrery-magi` binary when
/// available. During Phase 2 Step 3 the lookup is best-effort: if the
/// binary is missing, the capabilities handshake fails, or any of the
/// IPC errors out, callers fall back to the internal MagiCommand /
/// MagiMCPTools path. Step 4 will tighten this once the fallback path
/// is removed from the orrery binary itself.
public enum MagiSidecar {

    public struct ResolvedBinary {
        public let path: String
        public let version: String
        public let mcpSchema: [String: Any]?

        public init(path: String, version: String, mcpSchema: [String: Any]?) {
            self.path = path
            self.version = version
            self.mcpSchema = mcpSchema
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

    public static func isStrictMode() -> Bool {
        let value = ProcessInfo.processInfo.environment["ORRERY_MAGI_STRICT"]?.lowercased()
        return value == "1" || value == "true"
    }

    public static func resolveStrict() throws -> ResolvedBinary {
        guard let resolved = try resolveInternal(strict: true) else {
            throw MagiSidecarError.binaryNotFound
        }
        return resolved
    }

    public static func resolveOrFallback() throws -> ResolvedBinary? {
        try resolveInternal(strict: isStrictMode())
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
    /// with a watchdog timeout. Shared by the handshake path and the
    /// MCP tool handler to avoid pipe-drain deadlocks.
    public static func spawnAndCapture(
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

        var stdoutData = Data()
        var stderrData = Data()
        let stdoutQueue = DispatchQueue(label: "orrery.magi.sidecar.stdout")
        let stderrQueue = DispatchQueue(label: "orrery.magi.sidecar.stderr")
        let drainGroup = DispatchGroup()

        drainGroup.enter()
        stdoutQueue.async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }

        drainGroup.enter()
        stderrQueue.async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }

        let timeoutWork = DispatchWorkItem { [weak process, stdoutPipe, stderrPipe] in
            process?.terminate()
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        do {
            try process.run()
        } catch {
            timeoutWork.cancel()
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            return SpawnResult(
                stdout: "",
                stderr: "spawn failed: \(error.localizedDescription)",
                exitCode: -1,
                timedOut: false
            )
        }

        process.waitUntilExit()
        timeoutWork.cancel()

        let drainCompleted = drainGroup.wait(timeout: .now() + 1.0) == .success
        if !drainCompleted {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }

        let timedOut = (process.terminationReason == .uncaughtSignal && process.terminationStatus == 15)
            || !drainCompleted
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return SpawnResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: process.terminationStatus,
            timedOut: timedOut
        )
    }

    // MARK: - Private

    private static func resolveInternal(strict: Bool) throws -> ResolvedBinary? {
        guard let path = findBinary() else {
            if strict { throw MagiSidecarError.binaryNotFound }
            return nil
        }

        let caps: [String: Any]
        do {
            caps = try capabilities(path: path, strict: strict)
        } catch {
            if strict { throw error }
            return nil
        }

        let schemaVersion = caps["$schema_version"] as? Int ?? -1
        guard schemaVersion <= maxSchemaVersion, schemaVersion >= 0 else {
            let error = MagiSidecarError.schemaVersionUnsupported(
                found: schemaVersion,
                max: maxSchemaVersion
            )
            if strict { throw error }
            warn("\(error) Falling back to internal Magi.")
            return nil
        }

        let compatibility = caps["compatibility"] as? [String: Any]
        let protocolVersion = compatibility?["shim_protocol"] as? Int ?? -1
        guard protocolVersion >= shimProtocolVersion else {
            let error = MagiSidecarError.shimProtocolIncompatible(
                found: protocolVersion,
                required: shimProtocolVersion
            )
            if strict { throw error }
            warn("\(error) Falling back to internal Magi.")
            return nil
        }

        let tool = caps["tool"] as? [String: Any] ?? [:]
        let version = tool["version"] as? String ?? "?"

        switch runJSON(path: path, args: ["--print-mcp-schema"], timeout: 5) {
        case .success(let schema):
            return ResolvedBinary(path: path, version: version, mcpSchema: schema)
        case .failure:
            if strict { throw MagiSidecarError.mcpSchemaFetchFailed }
            warn("failed to fetch MCP schema from sidecar; registering hardcoded fallback schema.")
            return ResolvedBinary(path: path, version: version, mcpSchema: nil)
        }
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
        let result = spawnAndCapture(binary: path, args: args, timeout: timeout)
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

    private static func capabilities(path: String, strict: Bool) throws -> [String: Any] {
        switch runJSON(path: path, args: ["--capabilities"], timeout: 5) {
        case .success(let caps):
            return caps
        case .failure(let error):
            if strict { throw error }
            warn("\(error) Falling back to internal Magi.")
            throw error
        }
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("[orrery-magi] \(message)\n".utf8))
    }
}
