import Foundation

/// A discovered AI-tool session (one of claude-code / codex / gemini) that
/// orrery knows about — the result of scanning per-tool session files on
/// disk.
///
/// Historically this type lived as a nested `SessionsCommand.SessionEntry`,
/// but Magi extraction (D3) needed a top-level public DTO so
/// `SessionResolver.findScopedSessions` could become part of the public
/// API without dragging a command type into library consumers.
///
/// `SessionsCommand.SessionEntry` remains as a `public typealias` for
/// source compatibility.
public struct SessionEntry: Equatable {
    public let id: String
    public let firstMessage: String
    public let lastTime: Date?
    public let userCount: Int
    public var isActive: Bool

    public init(id: String, firstMessage: String, lastTime: Date?, userCount: Int, isActive: Bool = false) {
        self.id = id
        self.firstMessage = firstMessage
        self.lastTime = lastTime
        self.userCount = userCount
        self.isActive = isActive
    }
}
