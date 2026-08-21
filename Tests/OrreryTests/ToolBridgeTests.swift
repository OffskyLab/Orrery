import Foundation
import Testing
import AIToolKit
@testable import OrreryCore

/// While call sites migrate, the enum and AIToolKit's description of a tool
/// both describe the same three tools. If the bridge drifts from the enum,
/// behaviour changes depending on which one a given call site happens to
/// consult — so these assert they agree.
///
/// Note that most of these are pass-through assertions rather than hardcoded
/// values. Carrying the enum's answer across unchanged is the bridge's job, and
/// an assertion phrased that way keeps holding when the enum's answer changes
/// on another branch. The one place the bridge deliberately does *not* pass
/// through — gemini's config-dir variable — is pinned to concrete values below.
@Suite("Tool → AITool bridge")
struct ToolBridgeTests {

    @Test("every case bridges to an AITool carrying its rawValue as id")
    func idMatchesRawValue() {
        for tool in Tool.allCases {
            #expect(tool.aiTool.id == tool.rawValue)
        }
    }

    /// Tautological today — `configDirectoryName` *is* the last component of
    /// `defaultConfigDir`. Kept anyway: it is what fails if either side later
    /// grows its own naming rule and the two stop describing one directory.
    @Test("the bridged config directory name matches the enum's default dir")
    func configDirectoryNameMatches() {
        for tool in Tool.allCases {
            #expect(tool.aiTool.configDirectoryName == tool.defaultConfigDir.lastPathComponent)
        }
    }

    @Test("display name carries across unchanged")
    func displayNameCarriesAcross() {
        for tool in Tool.allCases {
            #expect(tool.aiTool.displayName == tool.displayName)
        }
    }

    @Test("install command and setup support carry across unchanged")
    func installCarriesAcross() {
        for tool in Tool.allCases {
            #expect(tool.aiTool.installCommand == tool.installCommand)
            #expect(tool.aiTool.supportsSetup == tool.supportsSetup)
        }
    }

    @Test("session subdirectories and colour carry across unchanged")
    func sessionsAndColourCarryAcross() {
        for tool in Tool.allCases {
            #expect(tool.aiTool.sessionSubdirectories == tool.sessionSubdirectories)
            #expect(tool.aiTool.ansiColor == tool.ansiColor)
            #expect(tool.aiTool.coloredTag == tool.coloredTag)
        }
    }

    /// Asserted as pass-through, not against literal commands: whether a tool
    /// has a scriptable login is a fact the enum owns and that is being
    /// actively corrected elsewhere. The bridge's contract is that it reports
    /// whatever the enum says, whichever way that lands.
    @Test("login command carries across, nil included")
    func loginCarriesAcross() {
        for tool in Tool.allCases {
            #expect(tool.aiTool.authLoginCommand == tool.authLoginCommand)
        }
        #expect(Tool.claude.aiTool.authLoginCommand == Tool.claude.authLoginCommand)
        #expect(Tool.gemini.aiTool.authLoginCommand == Tool.gemini.authLoginCommand)
    }

    /// The bridge is where the enum's existing lie gets corrected: gemini-cli
    /// ignores GEMINI_CONFIG_DIR and reads only `$HOME/.gemini`, so the bridged
    /// value is nil even though `Tool.gemini.envVarName` still returns the
    /// string. This one is hardcoded on both sides on purpose — the divergence
    /// is the point, and it must not quietly heal in either direction.
    @Test("gemini bridges to no config-dir variable")
    func geminiHasNoConfigDirVariable() {
        #expect(Tool.gemini.aiTool.configDirEnvVar == nil)
        #expect(Tool.gemini.envVarName == "GEMINI_CONFIG_DIR")
        #expect(Tool.claude.aiTool.configDirEnvVar == "CLAUDE_CONFIG_DIR")
        #expect(Tool.codex.aiTool.configDirEnvVar == "CODEX_HOME")
    }
}
