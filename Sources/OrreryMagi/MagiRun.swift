import Foundation
import OrreryCore

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

public struct MagiRole: Codable, Equatable {
    public let id: String
    public let label: String
    public let instruction: String
}

public enum MagiRolePreset: String, CaseIterable, Codable {
    case balanced
    case adversarial
    case security

    public var roles: [MagiRole] {
        switch self {
        case .balanced:
            return [
                MagiRole(id: "verifier", label: "Verifier",
                         instruction: "Prioritize finding risks, assumption gaps, and verification holes. Challenge: Is this really correct?"),
                MagiRole(id: "pragmatist", label: "Pragmatist",
                         instruction: "Prioritize estimating delivery cost, complexity, and operability. Challenge: Is this worth it? Can we ship it?"),
                MagiRole(id: "strategist", label: "Strategist",
                         instruction: "Prioritize evaluating module boundaries, extensibility, and long-term evolution. Challenge: Will this hold up in 6 months?"),
            ]
        case .adversarial:
            return [
                MagiRole(id: "devils-advocate", label: "Devil's Advocate",
                         instruction: "Actively argue against the proposal. Find every flaw, edge case, and reason it could fail."),
                MagiRole(id: "optimist", label: "Optimist",
                         instruction: "Argue for the proposal's strengths. Highlight benefits, opportunities, and positive outcomes."),
                MagiRole(id: "mediator", label: "Mediator",
                         instruction: "Synthesize both sides. Identify common ground and propose balanced compromises."),
            ]
        case .security:
            return [
                MagiRole(id: "attacker", label: "Attacker",
                         instruction: "Think like an attacker. Find vulnerabilities, attack surfaces, and exploitation paths."),
                MagiRole(id: "defender", label: "Defender",
                         instruction: "Design defenses. Propose mitigations, hardening measures, and monitoring strategies."),
                MagiRole(id: "auditor", label: "Auditor",
                         instruction: "Verify compliance. Check against standards, best practices, and regulatory requirements."),
            ]
        }
    }
}

public struct MagiAgentResponse: Codable {
    public let tool: Tool
    public let role: MagiRole?
    public let rawOutput: String
    public let positions: [MagiPositionEntry]?
    public let votes: [MagiVote]?
    public let parseSuccess: Bool
    public let exitCode: Int32?
    public let stderrOutput: String?
    public let timedOut: Bool?
    public let duration: TimeInterval?
    public let sessionId: String?
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

public struct FinalVerdict: Codable {
    public let decisions: [VerdictDecision]
    public let openQuestions: [String]
    public let constraints: [String]
}

public struct VerdictDecision: Codable {
    public let subtopic: String
    public let status: ConsensusStatus
    public let summary: String
    public let reasoning: String
    public let dissent: String?
}

public struct MagiRun: Codable {
    public let runId: String
    public let topic: String
    public let participants: [Tool]
    public var roleAssignments: [String: MagiRole]?
    public let environment: String?
    public var rounds: [MagiRound]
    public var finalConsensus: [ConsensusItem]?
    public var sessionMap: [String: String]?
    public var finalVerdict: FinalVerdict?
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
