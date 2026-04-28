import XCTest
@testable import OrreryCore

final class SpecSandboxPolicyTests: XCTestCase {

    // MARK: - Allowlist

    func testSwiftBuildAllowed() {
        XCTAssertEqual(SpecSandboxPolicy.decide(command: "swift build"), .allowed)
    }

    func testSwiftTestWithArgsAllowed() {
        XCTAssertEqual(
            SpecSandboxPolicy.decide(command: "swift test --filter Foo"),
            .allowed
        )
    }

    func testGrepAllowed() {
        XCTAssertEqual(
            SpecSandboxPolicy.decide(command: "grep 'pattern' file.txt"),
            .allowed
        )
    }

    func testLeadingWhitespaceTrimmed() {
        XCTAssertEqual(SpecSandboxPolicy.decide(command: "   swift build   "), .allowed)
    }

    // MARK: - Word-boundary enforcement

    func testPrefixGrepx_notAllowed_wordBoundary() {
        let decision = SpecSandboxPolicy.decide(command: "grepx something")
        if case .blocked = decision {
            // expected
        } else {
            XCTFail("expected blocked, got \(decision)")
        }
    }

    // MARK: - Blocklist

    func testRmBlocked() {
        let decision = SpecSandboxPolicy.decide(command: "rm -rf /")
        XCTAssertEqual(decision, .blocked(reason: "blocklist:rm"))
    }

    func testSudoBlocked() {
        let decision = SpecSandboxPolicy.decide(command: "sudo ls")
        XCTAssertEqual(decision, .blocked(reason: "blocklist:sudo"))
    }

    func testDdBlocked() {
        let decision = SpecSandboxPolicy.decide(command: "dd if=/dev/zero of=/tmp/bomb")
        XCTAssertEqual(decision, .blocked(reason: "blocklist:dd"))
    }

    func testGitPushBlocked() {
        let decision = SpecSandboxPolicy.decide(command: "git push origin main")
        XCTAssertEqual(decision, .blocked(reason: "blocklist:git push"))
    }

    func testMixedAllowlistAndBlocklist_blocklistWins() {
        // `git diff` is allowlisted, but `git push` in the same line is not.
        let decision = SpecSandboxPolicy.decide(command: "git diff && git push")
        XCTAssertEqual(decision, .blocked(reason: "blocklist:git push"))
    }

    func testPipeToShBlocked() {
        XCTAssertEqual(
            SpecSandboxPolicy.decide(command: "echo hi | sh"),
            .blocked(reason: "blocklist:| sh")
        )
    }

    func testPipeToBashBlocked() {
        let decision = SpecSandboxPolicy.decide(command: "echo hi | bash")
        if case .blocked = decision {
            // either "| bash" or "bash -c" would catch it depending on form
        } else {
            XCTFail("expected blocked, got \(decision)")
        }
    }

    func testCdRootBlocked() {
        let decision = SpecSandboxPolicy.decide(command: "cd /tmp && ls")
        if case .blocked = decision {
            // expected
        } else {
            XCTFail("expected blocked, got \(decision)")
        }
    }

    func testPushdBlocked() {
        let decision = SpecSandboxPolicy.decide(command: "pushd /foo")
        XCTAssertEqual(decision, .blocked(reason: "blocklist:pushd"))
    }

    // MARK: - Not-in-allowlist fallback

    func testUnknownCommandBlocked() {
        let decision = SpecSandboxPolicy.decide(command: "mysterious_cmd --flag")
        XCTAssertEqual(decision, .blocked(reason: "not in allowlist"))
    }

    func testEmptyCommandBlocked() {
        let decision = SpecSandboxPolicy.decide(command: "   ")
        XCTAssertEqual(decision, .blocked(reason: "empty command"))
    }

    // MARK: - lintPythonRegex

    func testPythonAllowed_astImport() {
        let snippet = "import ast; print(ast.parse('1'))"
        XCTAssertEqual(SpecSandboxPolicy.lintPythonRegex(snippet: snippet), .allowed)
    }

    func testPythonBlocked_dunderImport() {
        let snippet = "__import__('os').system('x')"
        let d = SpecSandboxPolicy.lintPythonRegex(snippet: snippet)
        if case .blocked = d {
            // expected
        } else {
            XCTFail("expected blocked, got \(d)")
        }
    }

    func testPythonBlocked_execCall() {
        let d = SpecSandboxPolicy.lintPythonRegex(snippet: "exec('print(1)')")
        if case .blocked = d { /* ok */ } else { XCTFail("expected blocked, got \(d)") }
    }

    func testPythonBlocked_evalCall() {
        let d = SpecSandboxPolicy.lintPythonRegex(snippet: "x = eval('1+1')")
        if case .blocked = d { /* ok */ } else { XCTFail("expected blocked, got \(d)") }
    }

    func testPythonBlocked_openForWrite() {
        let d = SpecSandboxPolicy.lintPythonRegex(snippet: "open('f', 'w')")
        if case .blocked = d { /* ok */ } else { XCTFail("expected blocked, got \(d)") }
    }

    func testPythonBlocked_disallowedImport() {
        let d = SpecSandboxPolicy.lintPythonRegex(snippet: "import os")
        if case .blocked = d { /* ok */ } else { XCTFail("expected blocked, got \(d)") }
    }

    func testPythonAllowed_reImport() {
        let d = SpecSandboxPolicy.lintPythonRegex(snippet: "import re; print(re.match('a', 'abc'))")
        XCTAssertEqual(d, .allowed)
    }
}
