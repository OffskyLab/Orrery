import Foundation

public enum MagiPosition: String, Codable {
    case agree
    case disagree
    case conditional
}

public struct MagiPositionEntry: Codable {
    public let subtopic: String
    public let position: MagiPosition
    public let reasoning: String
}

public struct MagiVote: Codable {
    public let claimId: String
    public let vote: MagiPosition
    public let counterpoint: String?
}

public struct MagiAgentResponse: Codable {
    public let tool: Tool
    public let rawOutput: String
    public let positions: [MagiPositionEntry]?
    public let votes: [MagiVote]?
    public let parseSuccess: Bool
}

public enum ConsensusStatus: String, Codable {
    case agreed
    case majority
    case disputed
    case pending
}

public struct ConsensusItem: Codable {
    public let subtopic: String
    public var status: ConsensusStatus
    public var positions: [String: MagiPosition]
}

public struct MagiRound: Codable {
    public let roundNumber: Int
    public let responses: [MagiAgentResponse]
    public let consensusSnapshot: [ConsensusItem]
    public let votes: [MagiAgentResponse]?
}

public enum MagiRunStatus: String, Codable {
    case inProgress
    case maxRoundsReached
    case converged
}

public struct MagiRun: Codable {
    public let runId: String
    public let topic: String
    public let participants: [Tool]
    public let environment: String?
    public var rounds: [MagiRound]
    public var finalConsensus: [ConsensusItem]?
    public var status: MagiRunStatus
    public let createdAt: String
    public var updatedAt: String

    public func save(store: EnvironmentStore) throws {
        let dir = store.homeURL.appendingPathComponent("magi")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(runId).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file)
    }
}
