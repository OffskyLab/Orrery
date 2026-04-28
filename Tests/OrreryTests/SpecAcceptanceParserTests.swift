import XCTest
@testable import OrreryCore

final class SpecAcceptanceParserTests: XCTestCase {

    // MARK: - Fixture A: full happy path

    func testFixtureA_checklistAndCommandsParsedInOrder() throws {
        let md = """
        # Title

        ## 目標

        Something.

        ## 驗收標準

        - [ ] first check
        - [x] second check
        - [ ] third check
        - [X] fourth check

        ```bash
        swift build
        swift test
        echo done
        ```

        ## Next

        Out of scope.
        """

        let (checklist, commands) = try SpecAcceptanceParser.parse(markdown: md)

        XCTAssertEqual(checklist.map(\.text), [
            "first check",
            "second check",
            "third check",
            "fourth check"
        ])
        XCTAssertEqual(commands.map(\.line), [
            "swift build",
            "swift test",
            "echo done"
        ])
    }

    // MARK: - Fixture B: missing acceptance section throws

    func testFixtureB_missingSectionThrows() {
        let md = """
        # Title

        ## 目標

        No acceptance here.
        """

        XCTAssertThrowsError(try SpecAcceptanceParser.parse(markdown: md)) { error in
            let desc = String(describing: error)
            XCTAssertTrue(desc.contains("## 驗收標準") || desc.contains("acceptance"),
                          "expected missingAcceptanceSection message, got: \(desc)")
        }
    }

    // MARK: - Fixture C: comments and empty lines are ignored inside fence

    func testFixtureC_fenceSkipsCommentsAndBlankLines() throws {
        let md = """
        ## 驗收標準

        ```bash
        # this is a comment

        swift build

        # another comment
        swift test
        ```
        """

        let (_, commands) = try SpecAcceptanceParser.parse(markdown: md)
        XCTAssertEqual(commands.map(\.line), ["swift build", "swift test"])
    }

    // MARK: - Fixture D: backslash line continuation merges

    func testFixtureD_backslashContinuationMerges() throws {
        let md = """
        ## 驗收標準

        ```bash
        swift test \\
          --filter Foo \\
          --parallel
        echo ok
        ```
        """

        let (_, commands) = try SpecAcceptanceParser.parse(markdown: md)
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].line, "swift test --filter Foo --parallel")
        XCTAssertEqual(commands[1].line, "echo ok")
    }

    // MARK: - Fixture E: ```sh fence recognised

    func testFixtureE_shFenceRecognised() throws {
        let md = """
        ## 驗收標準

        ```sh
        swift build
        ```
        """

        let (_, commands) = try SpecAcceptanceParser.parse(markdown: md)
        XCTAssertEqual(commands.map(\.line), ["swift build"])
    }

    // MARK: - Fixture F: unclosed fence still yields collected commands

    func testFixtureF_unclosedFenceYieldsCollected() throws {
        let md = """
        ## 驗收標準

        ```bash
        swift build
        swift test
        """  // no closing fence, no trailing section

        let (_, commands) = try SpecAcceptanceParser.parse(markdown: md)
        XCTAssertEqual(commands.map(\.line), ["swift build", "swift test"])
    }

    // MARK: - Acceptance Criteria (English heading)

    func testEnglishHeadingAlsoAccepted() throws {
        let md = """
        ## Acceptance Criteria

        - [ ] only check

        ```bash
        swift build
        ```
        """
        let (checklist, commands) = try SpecAcceptanceParser.parse(markdown: md)
        XCTAssertEqual(checklist.map(\.text), ["only check"])
        XCTAssertEqual(commands.map(\.line), ["swift build"])
    }

    // MARK: - Heredoc basic

    func testHeredoc_basicUnquoted_mergesBlockAsSingleCommand() throws {
        let md = """
        ## 驗收標準

        ```bash
        cat <<EOF
        line one
        line two
        EOF
        echo done
        ```
        """
        let (_, commands) = try SpecAcceptanceParser.parse(markdown: md)
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].line, "cat <<EOF\nline one\nline two\nEOF")
        XCTAssertEqual(commands[1].line, "echo done")
    }

    // MARK: - Heredoc with single-quoted delimiter + leading pipe

    func testHeredoc_singleQuotedWithPipe_mergesBlock() throws {
        let md = """
        ## 驗收標準

        ```bash
        cat <<'EOF' | grep foo | tail -1
        body line 1
        body line 2
        EOF
        ```
        """
        let (_, commands) = try SpecAcceptanceParser.parse(markdown: md)
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(commands[0].line.contains("cat <<'EOF' | grep foo | tail -1"))
        XCTAssertTrue(commands[0].line.contains("body line 1"))
        XCTAssertTrue(commands[0].line.contains("body line 2"))
        XCTAssertTrue(commands[0].line.hasSuffix("EOF"))
    }

    // MARK: - Heredoc double-quoted delimiter

    func testHeredoc_doubleQuoted_mergesBlock() throws {
        let md = """
        ## 驗收標準

        ```bash
        cat <<"END"
        hello
        END
        ```
        """
        let (_, commands) = try SpecAcceptanceParser.parse(markdown: md)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].line, "cat <<\"END\"\nhello\nEND")
    }

    // MARK: - Heredoc with <<- (strip leading tabs on terminator)

    func testHeredoc_dashForm_stripsTabsOnTerminatorLine() throws {
        // Use actual tabs in fixture — the terminator has a leading tab.
        let md = """
        ## 驗收標準

        ```bash
        cat <<-EOF
        \tindented body
        \tEOF
        echo after
        ```
        """
        let (_, commands) = try SpecAcceptanceParser.parse(markdown: md)
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].line,
                       "cat <<-EOF\n\tindented body\n\tEOF")
        XCTAssertEqual(commands[1].line, "echo after")
    }

    // MARK: - Custom delimiter word (not EOF/END)

    func testHeredoc_customDelimiter() throws {
        let md = """
        ## 驗收標準

        ```bash
        cat <<PAYLOAD
        {"k":"v"}
        PAYLOAD
        ```
        """
        let (_, commands) = try SpecAcceptanceParser.parse(markdown: md)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].line, "cat <<PAYLOAD\n{\"k\":\"v\"}\nPAYLOAD")
    }

    // MARK: - Real-world shape from implement spec (JSON-RPC piped through MCP server)

    func testHeredoc_mcpJsonRpcBlock_keepsBodyIntact() throws {
        let md = """
        ## 驗收標準

        ```bash
        cat <<'EOF' | .build/debug/orrery mcp-server | tail -1
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
        EOF
        ```
        """
        let (_, commands) = try SpecAcceptanceParser.parse(markdown: md)
        XCTAssertEqual(commands.count, 1)
        // All three JSON-RPC lines + EOF must be in one single Command string.
        XCTAssertTrue(commands[0].line.contains("\"initialize\""))
        XCTAssertTrue(commands[0].line.contains("\"notifications/initialized\""))
        XCTAssertTrue(commands[0].line.contains("\"tools/list\""))
        XCTAssertTrue(commands[0].line.hasSuffix("EOF"))
    }

    // MARK: - Two separate heredocs in the same fence

    func testHeredoc_twoBlocksInSameFence_eachBecomesOneCommand() throws {
        let md = """
        ## 驗收標準

        ```bash
        cat <<A
        one
        A
        cat <<B
        two
        B
        ```
        """
        let (_, commands) = try SpecAcceptanceParser.parse(markdown: md)
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].line, "cat <<A\none\nA")
        XCTAssertEqual(commands[1].line, "cat <<B\ntwo\nB")
    }

    // MARK: - Heredoc that does not close before fence end (graceful EOF flush)

    func testHeredoc_unclosedAtFenceEnd_stillEmittedAsBestEffort() throws {
        let md = """
        ## 驗收標準

        ```bash
        cat <<EOF
        body
        """  // no EOF line, no fence close — tests the EOF-flush path
        let (_, commands) = try SpecAcceptanceParser.parse(markdown: md)
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(commands[0].line.contains("cat <<EOF"))
        XCTAssertTrue(commands[0].line.contains("body"))
    }

    // MARK: - validateStructure (T1, DI5 safety net)

    private static let allFourHeadings = """
    # Title

    ## 來源

    path

    ## 介面合約（Interface Contract）

    public protocol Foo { func bar() }

    ## 改動檔案

    | file | change |
    | --- | --- |

    ## 實作步驟

    1. do stuff

    ## 驗收標準

    - [ ] done
    """

    func testValidateStructure_allFourHeadingsPresent_passes() throws {
        XCTAssertNoThrow(try SpecAcceptanceParser.validateStructure(markdown: Self.allFourHeadings))
    }

    func testValidateStructure_englishHeadings_passes() throws {
        let md = """
        ## Interface Contract
        x
        ## Changed Files
        x
        ## Implementation Steps
        x
        ## Acceptance Criteria
        x
        """
        XCTAssertNoThrow(try SpecAcceptanceParser.validateStructure(markdown: md))
    }

    func testValidateStructure_missingInterface_throws() {
        let md = Self.allFourHeadings.replacingOccurrences(
            of: "## 介面合約（Interface Contract）",
            with: "## 某個別的段落"
        )
        XCTAssertThrowsError(try SpecAcceptanceParser.validateStructure(markdown: md)) { err in
            let desc = String(describing: err)
            XCTAssertTrue(desc.contains("介面合約") || desc.contains("Interface Contract"),
                          "expected InterfaceContract error, got: \(desc)")
        }
    }

    func testValidateStructure_missingChangedFiles_throws() {
        let md = Self.allFourHeadings.replacingOccurrences(
            of: "## 改動檔案",
            with: "## 某個別的段落"
        )
        XCTAssertThrowsError(try SpecAcceptanceParser.validateStructure(markdown: md)) { err in
            let desc = String(describing: err)
            XCTAssertTrue(desc.contains("改動檔案") || desc.contains("Changed Files"),
                          "expected ChangedFiles error, got: \(desc)")
        }
    }

    func testValidateStructure_missingImplementationSteps_throws() {
        let md = Self.allFourHeadings.replacingOccurrences(
            of: "## 實作步驟",
            with: "## 某個別的段落"
        )
        XCTAssertThrowsError(try SpecAcceptanceParser.validateStructure(markdown: md)) { err in
            let desc = String(describing: err)
            XCTAssertTrue(desc.contains("實作步驟") || desc.contains("Implementation Steps"),
                          "expected ImplementationSteps error, got: \(desc)")
        }
    }

    func testValidateStructure_missingAcceptance_throws() {
        let md = Self.allFourHeadings.replacingOccurrences(
            of: "## 驗收標準",
            with: "## 某個別的段落"
        )
        XCTAssertThrowsError(try SpecAcceptanceParser.validateStructure(markdown: md)) { err in
            let desc = String(describing: err)
            XCTAssertTrue(desc.contains("驗收標準") || desc.contains("Acceptance Criteria"),
                          "expected Acceptance error, got: \(desc)")
        }
    }

    func testValidateStructure_interfaceWithoutParenthetical_passes() throws {
        let md = """
        ## 介面合約
        x
        ## 改動檔案
        x
        ## 實作步驟
        x
        ## 驗收標準
        x
        """
        XCTAssertNoThrow(try SpecAcceptanceParser.validateStructure(markdown: md))
    }

    func testValidateStructure_orderIndependent() throws {
        let md = """
        ## 驗收標準
        x
        ## 實作步驟
        x
        ## 改動檔案
        x
        ## 介面合約
        x
        """
        XCTAssertNoThrow(try SpecAcceptanceParser.validateStructure(markdown: md))
    }

    func testValidateStructure_missingMultiple_reportsFirstByCheckOrder() {
        // Check order is Interface → ChangedFiles → Implementation → Acceptance;
        // if BOTH Interface and Acceptance missing, Interface error should surface first.
        let md = """
        ## 改動檔案
        x
        ## 實作步驟
        x
        """
        XCTAssertThrowsError(try SpecAcceptanceParser.validateStructure(markdown: md)) { err in
            let desc = String(describing: err)
            XCTAssertTrue(desc.contains("介面合約") || desc.contains("Interface Contract"),
                          "expected InterfaceContract (first in check order), got: \(desc)")
        }
    }

    // MARK: - Section boundary — stops at next `## ` heading

    func testStopsAtNextSecondLevelHeading() throws {
        let md = """
        ## 驗收標準

        - [ ] inside

        ## Later

        - [ ] outside (should be ignored)

        ```bash
        should_not_appear
        ```
        """
        let (checklist, commands) = try SpecAcceptanceParser.parse(markdown: md)
        XCTAssertEqual(checklist.map(\.text), ["inside"])
        XCTAssertTrue(commands.isEmpty)
    }
}
