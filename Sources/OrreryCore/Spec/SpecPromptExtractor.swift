import ArgumentParser
import Foundation

/// Builds the prompt sent to the delegate agent (claude-code / codex / gemini
/// subprocess) for `orrery spec-run --mode implement`.
///
/// Design (DI4 妥協版)：
/// - **Inline**: `介面合約` + `驗收標準`（spec 的 API shape + stop condition；delegate 一定要看）
/// - **Read via spec_path**: `改動檔案` / `實作步驟` / `失敗路徑` / `不改動的部分`（可藉 delegate
///   本身的 Read tool 讀取，避免 prompt baseline 隨 spec 長度膨脹）
///
/// See docs/tasks/2026-04-20-orrery-spec-implement-mvp.md §5.
public struct SpecPromptExtractor {

    // MARK: - Public API

    /// Return the full markdown of the `## 介面合約` section (including the
    /// heading line), up to but not including the next `##` heading.
    /// Accepts Chinese, English, and parenthetical-annotated heading variants.
    public static func extractInterfaceContract(markdown: String) throws -> String {
        try extractSection(
            markdown: markdown,
            variants: ["## 介面合約", "## Interface Contract"],
            missingError: L10n.SpecRun.missingInterfaceContractSection
        )
    }

    /// Return the full markdown of the `## 驗收標準` section.
    public static func extractAcceptance(markdown: String) throws -> String {
        try extractSection(
            markdown: markdown,
            variants: ["## 驗收標準", "## Acceptance Criteria"],
            missingError: L10n.SpecRun.missingAcceptanceSection
        )
    }

    /// Build the full prompt to hand to the delegate subprocess.
    ///
    /// The delegate is expected to have `Read` / `Edit` / `Bash` / `Grep`
    /// tools; we therefore give it the spec path so it can consume the
    /// variable-length sections itself, and inline only the two short,
    /// structurally stable sections that define API shape and stop
    /// condition.
    public static func buildImplementPrompt(
        markdown: String,
        specPath: String,
        sessionId: String,
        progressLogPath: String,
        tokenBudget: Int?
    ) throws -> String {
        let interfaceContract = try extractInterfaceContract(markdown: markdown)
        let acceptance = try extractAcceptance(markdown: markdown)

        var sections: [String] = []

        sections.append("""
            # 任務

            閱讀下方指定路徑的 spec 並實作其中所有的「改動檔案」、「實作步驟」段落；
            不能違反「不改動的部分」與「失敗路徑」的約束。此 prompt 已 inline 兩段關鍵
            section — 介面合約（API shape）與 驗收標準（停止條件）— 請同步閱讀。
            """)

        sections.append("""
            # Spec 路徑

            \(specPath)

            使用 Read 工具讀完整 spec，重點關注：
            - `## 改動檔案` 表列出所有需要編輯／新增的檔案
            - `## 實作步驟` 是逐步任務分解
            - `## 失敗路徑` 定義錯誤處理契約
            - `## 不改動的部分` 標示不可動的既有行為
            """)

        sections.append("""
            # 介面合約（必讀 inline）

            \(interfaceContract)
            """)

        sections.append("""
            # 驗收標準（停止條件）

            \(acceptance)
            """)

        sections.append("""
            # 進度回報協議

            每個步驟邊界（進入 / 完成 / 跳過）請 append 一行 JSON 到環境變數
            `$ORRERY_SPEC_PROGRESS_LOG` 指向的檔案（目前為 `\(progressLogPath)`）：

            ```json
            {"ts":"<ISO8601>","step":"step-<N>","event":"start|done|skip","note":"<短描述>"}
            ```

            範例：
            ```
            {"ts":"2026-04-20T12:00:00Z","step":"step-1","event":"start","note":"create SpecPromptExtractor.swift"}
            {"ts":"2026-04-20T12:02:00Z","step":"step-1","event":"done","note":"file created + tests"}
            ```

            同時保留下列環境變數以供識別：
            - `$ORRERY_SPEC_SESSION_ID` = `\(sessionId)`
            - `$ORRERY_SPEC_PATH` = spec 絕對路徑
            """)

        var constraints: [String] = [
            "禁止執行 `git commit` / `git push` / `git reset` / `git stash` / `git checkout` 等會改動 repository 狀態的指令。",
            "禁止執行 `swift build` / `swift test` / 任何驗證型 shell 指令 — 那是 `orrery_spec_verify` phase 的職責。",
            "完成所有步驟後，請在最終回覆中輸出兩個結構化段落：`## Touched files`（明列所有新增／修改檔案路徑）、`## Completed steps`（對應 progress log 的 step 列表）。",
            "無法完成或需要放棄時，append 一筆 `event=\"skip\"` 的 progress log 並在最終回覆簡述原因；不要隱藏失敗。"
        ]
        if let budget = tokenBudget {
            constraints.append(
                "建議 token 預算：約 \(budget) tokens（僅為 hint，不強制；請避免無關 chain-of-thought）。"
            )
        }
        let constraintsBody = constraints.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        sections.append("""
            # 約束

            \(constraintsBody)
            """)

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Private helpers

    private static func extractSection(
        markdown: String,
        variants: [String],
        missingError message: String
    ) throws -> String {
        let lines = markdown.components(separatedBy: "\n")

        guard let startIndex = findHeadingIndex(lines: lines, variants: variants) else {
            throw ValidationError(message)
        }

        // Walk to the next `^##\s+` heading (exclusive).
        var endIndex = lines.count
        var i = startIndex + 1
        while i < lines.count {
            if lines[i].hasPrefix("## ") {
                endIndex = i
                break
            }
            i += 1
        }

        return lines[startIndex..<endIndex].joined(separator: "\n")
    }

    /// Find the first line index matching any variant, allowing optional
    /// parenthetical annotation or trailing whitespace.
    private static func findHeadingIndex(lines: [String], variants: [String]) -> Int? {
        for (idx, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            for variant in variants {
                if trimmed == variant
                    || trimmed.hasPrefix(variant + "（")
                    || trimmed.hasPrefix(variant + "(")
                    || trimmed.hasPrefix(variant + " ") {
                    return idx
                }
            }
        }
        return nil
    }
}
