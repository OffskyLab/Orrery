import XCTest
@testable import OrreryCore

final class SpecPromptExtractorTests: XCTestCase {

    // Minimal spec fixture covering all four mandatory headings with
    // distinct body content so tests can verify section boundaries.
    private static let fixture = """
    # Title

    ## 目標

    Preface text we should never see in extracts.

    ## 介面合約（Interface Contract）

    ```swift
    public protocol Foo { func bar() -> Int }
    ```

    interface notes.

    ## 改動檔案

    | File | Change |
    | --- | --- |
    | `Foo.swift` | new |

    ## 實作步驟

    1. create Foo.swift
    2. implement bar()

    ## 失敗路徑

    1. compile error → return nil

    ## 驗收標準

    - [ ] Foo.swift exists
    - [ ] `Foo().bar() == 42`

    ```bash
    swift build
    ```

    ## 不改動的部分

    - legacy Bar

    """

    // MARK: - extractInterfaceContract

    func testExtractInterface_returnsHeadingPlusBodyUpToNextSection() throws {
        let body = try SpecPromptExtractor.extractInterfaceContract(markdown: Self.fixture)
        XCTAssertTrue(body.hasPrefix("## 介面合約（Interface Contract）"),
                      "should begin with the heading; got:\n\(body.prefix(120))")
        XCTAssertTrue(body.contains("public protocol Foo"), "should inline API sketch")
        XCTAssertFalse(body.contains("## 改動檔案"),
                       "should stop before next ## heading")
    }

    func testExtractInterface_englishHeading() throws {
        let md = """
        ## Interface Contract
        english body
        ## Changed Files
        x
        ## Implementation Steps
        x
        ## Acceptance Criteria
        x
        """
        let body = try SpecPromptExtractor.extractInterfaceContract(markdown: md)
        XCTAssertTrue(body.hasPrefix("## Interface Contract"))
        XCTAssertTrue(body.contains("english body"))
    }

    func testExtractInterface_missingSection_throws() {
        let md = """
        ## 改動檔案
        x
        ## 實作步驟
        x
        ## 驗收標準
        x
        """
        XCTAssertThrowsError(try SpecPromptExtractor.extractInterfaceContract(markdown: md))
    }

    // MARK: - extractAcceptance

    func testExtractAcceptance_returnsHeadingPlusBody() throws {
        let body = try SpecPromptExtractor.extractAcceptance(markdown: Self.fixture)
        XCTAssertTrue(body.hasPrefix("## 驗收標準"))
        XCTAssertTrue(body.contains("Foo.swift exists"))
        XCTAssertTrue(body.contains("swift build"))
        XCTAssertFalse(body.contains("## 不改動的部分"),
                       "should stop before next ## heading")
    }

    func testExtractAcceptance_missingSection_throws() {
        let md = """
        ## 介面合約
        x
        ## 改動檔案
        x
        ## 實作步驟
        x
        """
        XCTAssertThrowsError(try SpecPromptExtractor.extractAcceptance(markdown: md))
    }

    // MARK: - buildImplementPrompt

    func testBuildImplementPrompt_containsBothInlineSections() throws {
        let prompt = try SpecPromptExtractor.buildImplementPrompt(
            markdown: Self.fixture,
            specPath: "/repo/docs/tasks/foo.md",
            sessionId: "SID-123",
            progressLogPath: "/tmp/progress.jsonl",
            tokenBudget: nil
        )
        XCTAssertTrue(prompt.contains("# 介面合約（必讀 inline）"))
        XCTAssertTrue(prompt.contains("public protocol Foo"))
        XCTAssertTrue(prompt.contains("# 驗收標準（停止條件）"))
        XCTAssertTrue(prompt.contains("Foo.swift exists"))
    }

    func testBuildImplementPrompt_containsSpecPathAndProgressLogPath() throws {
        let prompt = try SpecPromptExtractor.buildImplementPrompt(
            markdown: Self.fixture,
            specPath: "/repo/docs/tasks/foo.md",
            sessionId: "SID-123",
            progressLogPath: "/home/user/.orrery/spec-runs/SID-123.progress.jsonl",
            tokenBudget: nil
        )
        XCTAssertTrue(prompt.contains("/repo/docs/tasks/foo.md"))
        XCTAssertTrue(prompt.contains("SID-123"))
        XCTAssertTrue(prompt.contains("$ORRERY_SPEC_PROGRESS_LOG"))
        XCTAssertTrue(prompt.contains("/home/user/.orrery/spec-runs/SID-123.progress.jsonl"))
    }

    func testBuildImplementPrompt_containsConstraints() throws {
        let prompt = try SpecPromptExtractor.buildImplementPrompt(
            markdown: Self.fixture,
            specPath: "/s",
            sessionId: "S",
            progressLogPath: "/p",
            tokenBudget: nil
        )
        XCTAssertTrue(prompt.contains("# 約束"))
        XCTAssertTrue(prompt.contains("git commit"))
        XCTAssertTrue(prompt.contains("swift build"))
        XCTAssertTrue(prompt.contains("Touched files"))
        XCTAssertTrue(prompt.contains("Completed steps"))
    }

    func testBuildImplementPrompt_tokenBudgetHintAppearsWhenProvided() throws {
        let prompt = try SpecPromptExtractor.buildImplementPrompt(
            markdown: Self.fixture,
            specPath: "/s",
            sessionId: "S",
            progressLogPath: "/p",
            tokenBudget: 12345
        )
        XCTAssertTrue(prompt.contains("12345"))
        XCTAssertTrue(prompt.contains("token 預算"))
    }

    func testBuildImplementPrompt_tokenBudgetOmittedWhenNil() throws {
        let prompt = try SpecPromptExtractor.buildImplementPrompt(
            markdown: Self.fixture,
            specPath: "/s",
            sessionId: "S",
            progressLogPath: "/p",
            tokenBudget: nil
        )
        XCTAssertFalse(prompt.contains("token 預算"),
                       "the token_budget hint should NOT appear when caller passes nil")
    }

    func testBuildImplementPrompt_specMissingInterface_propagatesThrow() {
        let md = """
        ## 改動檔案
        x
        ## 實作步驟
        x
        ## 驗收標準
        x
        """
        XCTAssertThrowsError(try SpecPromptExtractor.buildImplementPrompt(
            markdown: md,
            specPath: "/s",
            sessionId: "S",
            progressLogPath: "/p",
            tokenBudget: nil
        ))
    }

    func testBuildImplementPrompt_specMissingAcceptance_propagatesThrow() {
        let md = """
        ## 介面合約
        x
        ## 改動檔案
        x
        ## 實作步驟
        x
        """
        XCTAssertThrowsError(try SpecPromptExtractor.buildImplementPrompt(
            markdown: md,
            specPath: "/s",
            sessionId: "S",
            progressLogPath: "/p",
            tokenBudget: nil
        ))
    }
}
