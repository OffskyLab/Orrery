import Foundation

public struct SpecSection: Codable, Sendable {
    public let title: String
    public let instruction: String
    public let required: Bool

    public init(title: String, instruction: String, required: Bool) {
        self.title = title
        self.instruction = instruction
        self.required = required
    }
}

public struct SpecTemplate: Codable, Sendable {
    public let name: String
    public let description: String
    public let sections: [SpecSection]

    public init(name: String, description: String, sections: [SpecSection]) {
        self.name = name
        self.description = description
        self.sections = sections
    }
}

public enum BuiltinProfiles {
    public static let `default` = SpecTemplate(
        name: "default",
        description: "Full 8-section contract-first spec",
        sections: [
            SpecSection(
                title: "來源",
                instruction: "State the source discussion MD path.",
                required: true),
            SpecSection(
                title: "目標",
                instruction: "2-4 sentences explaining WHY: what problem this solves, what value it delivers.",
                required: true),
            SpecSection(
                title: "介面合約（Interface Contract）",
                instruction: "For each new or modified function/API: function signature (input types → output types), thrown exceptions with specific error messages or L10n keys, observable behavior invariants, ID/key format descriptions. Mark inferred content with [inferred]. Clarify ownership for shared resources.",
                required: true),
            SpecSection(
                title: "改動檔案",
                instruction: "Markdown table: | File Path | Change Description |. One sentence per file describing what changed (not how). Include affected call sites.",
                required: true),
            SpecSection(
                title: "實作步驟",
                instruction: "One sub-section (Step N) per changed file. Numbered list of logic steps at function-level granularity. Include key constraints, boundary conditions, and required patterns. For migrations/refactors, list full logic including all branches.",
                required: true),
            SpecSection(
                title: "失敗路徑",
                instruction: "Describe error propagation chains: A raise → B catch → C return X. Distinguish recoverable vs non-recoverable errors. State conditions for each raise point.",
                required: true),
            SpecSection(
                title: "不改動的部分",
                instruction: "Explicitly list files/functions that must NOT be modified. Note any implicit behavioral changes from the modifications.",
                required: true),
            SpecSection(
                title: "驗收標準",
                instruction: "Checkable checklist (- [ ] per item). Each item must be a testable assertion. Include executable bash test commands. Split into: functional contract checklist + test commands section.",
                required: true),
        ])

    public static let minimal = SpecTemplate(
        name: "minimal",
        description: "Compact 5-section spec (spec-implement compatible)",
        sections: [
            SpecSection(
                title: "目標",
                instruction: "2-4 sentences explaining WHY: what problem this solves.",
                required: true),
            SpecSection(
                title: "介面合約（Interface Contract）",
                instruction: "Function signatures, input/output types, error types for each new or modified API.",
                required: true),
            SpecSection(
                title: "改動檔案",
                instruction: "Markdown table: | File Path | Change Description |. One row per changed file.",
                required: true),
            SpecSection(
                title: "實作步驟",
                instruction: "Numbered logic steps per changed file, function-level granularity.",
                required: true),
            SpecSection(
                title: "驗收標準",
                instruction: "Checkable checklist with testable assertions and executable bash test commands.",
                required: true),
        ])

    public static let rfc = SpecTemplate(
        name: "rfc",
        description: "RFC-style proposal",
        sections: [
            SpecSection(
                title: "Summary",
                instruction: "One paragraph overview of the proposal.",
                required: true),
            SpecSection(
                title: "Motivation",
                instruction: "Why is this change needed? What problems does it solve?",
                required: true),
            SpecSection(
                title: "Detailed Design",
                instruction: "Complete technical design with types, APIs, and implementation details.",
                required: true),
            SpecSection(
                title: "Alternatives Considered",
                instruction: "Other approaches considered but not adopted, with reasoning.",
                required: false),
            SpecSection(
                title: "Unresolved Questions",
                instruction: "Known open questions and items to be decided later.",
                required: false),
        ])

    public static let all: [SpecTemplate] = [`default`, minimal, rfc]

    public static func find(named name: String) -> SpecTemplate? {
        all.first { $0.name == name }
    }
}
