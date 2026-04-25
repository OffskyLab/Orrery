import Foundation
import OrreryCore

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
    }

    /// The shim's max-supported capabilities `$schema_version`.
    public static let maxSchemaVersion: Int = 1

    /// The shim's argv-construction protocol version.
    public static let shimProtocolVersion: Int = 1

    /// Discover the binary, run --capabilities, validate compatibility,
    /// and (best-effort) prefetch the MCP schema. Returns nil if any
    /// step fails — caller should fall back to the internal path.
    public static func resolve() -> ResolvedBinary? {
        guard let path = findBinary() else { return nil }
        guard let caps = runJSON(path: path, args: ["--capabilities"], timeout: 5) else {
            warn("--capabilities failed at \(path); falling back to internal Magi.")
            return nil
        }
        guard let schemaVersion = caps["$schema_version"] as? Int,
              schemaVersion <= maxSchemaVersion else {
            let version = caps["$schema_version"] as? Int ?? -1
            warn(
                "orrery-magi reports unsupported $schema_version=\(version) " +
                "(shim max=\(maxSchemaVersion)); falling back to internal Magi."
            )
            return nil
        }
        guard let compatibility = caps["compatibility"] as? [String: Any],
              let protocolVersion = compatibility["shim_protocol"] as? Int,
              protocolVersion >= shimProtocolVersion else {
            warn(
                "orrery-magi shim_protocol incompatible (shim requires >=\(shimProtocolVersion)); " +
                "falling back to internal Magi."
            )
            return nil
        }

        let tool = caps["tool"] as? [String: Any] ?? [:]
        let version = tool["version"] as? String ?? "?"
        let mcpSchema = runJSON(path: path, args: ["--print-mcp-schema"], timeout: 5)
        return ResolvedBinary(path: path, version: version, mcpSchema: mcpSchema)
    }

    /// Spawn the binary with the user's argv, wired through stdio,
    /// and propagate the exit code. Throws ExitCode of the subprocess.
    public static func dispatch(_ binary: ResolvedBinary, args: [String]) throws -> Never {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary.path)
        process.arguments = args
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        Foundation.exit(process.terminationStatus)
    }

    // MARK: - Private

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

    private static func runJSON(path: String, args: [String], timeout: TimeInterval) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        let timeoutWork = DispatchWorkItem { [weak process] in
            process?.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        do {
            try process.run()
        } catch {
            timeoutWork.cancel()
            return nil
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWork.cancel()

        guard process.terminationStatus == 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("[orrery-magi] \(message)\n".utf8))
    }
}
