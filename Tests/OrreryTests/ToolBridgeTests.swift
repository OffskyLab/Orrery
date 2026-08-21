import Foundation
import Testing
import AIToolKit
@testable import OrreryCore

/// While call sites migrate, the enum and the registry describe the same three
/// tools. If the bridge drifts from the enum, behaviour changes depending on
/// which one a given call site happens to consult — so these assert they agree.
@Suite("Tool → AITool bridge")
struct ToolBridgeTests {

    @Test("every case bridges to an AITool carrying its rawValue as id")
    func idMatchesRawValue() {
        for tool in Tool.allCases {
            #expect(tool.aiTool.id == tool.rawValue)
        }
    }

    @Test("the bridged config directory name matches the enum's default dir")
    func configDirectoryNameMatches() {
        for tool in Tool.allCases {
            #expect(tool.aiTool.configDirectoryName == tool.defaultConfigDir.lastPathComponent)
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
            #expect(tool.aiTool.coloredTag == tool.coloredTag)
        }
    }

    @Test("display name carries across unchanged")
    func displayNameCarriesAcross() {
        for tool in Tool.allCases {
            #expect(tool.aiTool.displayName == tool.displayName)
        }
    }

    @Test("login command carries across, including claude's nil")
    func loginCarriesAcross() {
        for tool in Tool.allCases {
            #expect(tool.aiTool.authLoginCommand == tool.authLoginCommand)
        }
        #expect(Tool.claude.aiTool.authLoginCommand == nil)
        #expect(Tool.gemini.aiTool.authLoginCommand == ["gemini", "auth", "login"])
    }

    /// The bridge is where the enum's existing lie gets corrected: gemini-cli
    /// ignores GEMINI_CONFIG_DIR, so the bridged value is nil even though
    /// `Tool.gemini.envVarName` still returns the string.
    @Test("gemini bridges to no config-dir variable")
    func geminiHasNoConfigDirVariable() {
        #expect(Tool.gemini.aiTool.configDirEnvVar == nil)
        #expect(Tool.gemini.envVarName == "GEMINI_CONFIG_DIR")
        #expect(Tool.claude.aiTool.configDirEnvVar == "CLAUDE_CONFIG_DIR")
        #expect(Tool.codex.aiTool.configDirEnvVar == "CODEX_HOME")
    }
}
