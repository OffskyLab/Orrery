import Foundation

/// One supervised tool session, persisted at
/// `<home>/phantom/<supervisor-pid>/meta.json`.
///
/// `supervisorStartedAt` exists to defeat pid recycling: a pid alone is not a
/// stable identity, so liveness is "pid responds to signal 0 AND its start
/// time still matches what we recorded". Without it, a crashed supervisor's
/// leftover directory could be mistaken for an unrelated new process that
/// happened to get the same pid.
public struct PhantomEntry: Codable, Sendable, Equatable {
    public enum SessionIdSource: String, Codable, Sendable {
        /// Authoritative — reported by claude's own SessionStart hook.
        case hook
        /// Best-effort — inferred by scanning session files by mtime.
        case probe
    }

    public var schema: Int
    public var supervisorPid: Int32
    public var supervisorStartedAt: Double
    public var tool: String
    public var tty: String?
    public var cwd: String
    public var workspace: String?
    public var account: String?
    public var sessionId: String?
    public var sessionIdSource: SessionIdSource
    public var updatedAt: Double

    public init(
        schema: Int = 1,
        supervisorPid: Int32,
        supervisorStartedAt: Double,
        tool: String,
        tty: String?,
        cwd: String,
        workspace: String?,
        account: String?,
        sessionId: String?,
        sessionIdSource: SessionIdSource,
        updatedAt: Double
    ) {
        self.schema = schema
        self.supervisorPid = supervisorPid
        self.supervisorStartedAt = supervisorStartedAt
        self.tool = tool
        self.tty = tty
        self.cwd = cwd
        self.workspace = workspace
        self.account = account
        self.sessionId = sessionId
        self.sessionIdSource = sessionIdSource
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case supervisorPid = "supervisor_pid"
        case supervisorStartedAt = "supervisor_started_at"
        case tool
        case tty
        case cwd
        case workspace
        case account
        case sessionId = "session_id"
        case sessionIdSource = "session_id_source"
        case updatedAt = "updated_at"
    }
}
