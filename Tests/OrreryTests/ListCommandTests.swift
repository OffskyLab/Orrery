import Testing
import Foundation
@testable import OrreryCore

@Suite("SandboxCommand.List")
struct ListCommandTests {
    let originPath = URL(fileURLWithPath: "/tmp/origin")

    /// `ListCommand` resolves claude's config dir through the registry, which
    /// `main.swift` fills at bootstrap and a test process does not. Without this
    /// the suite would exercise the "claude is unavailable" branch while looking
    /// exactly as green as it does now.
    init() { seedSharedRegistryForTests() }

    @Test("groups by tool, not by workspace")
    func groupsByTool() {
        let workspaces = [EnvironmentStore.WorkspaceListing(name: "work", path: URL(fileURLWithPath: "/tmp/work"))]
        let acct = Account(tool: .claude, displayName: "grady", workspace: "work")
        let output = SandboxCommand.List.render(
            workspaces: workspaces, accountsByTool: [.claude: [acct]], originPath: originPath)
        #expect(output.contains("[Claude]"))
        #expect(output.contains("[Codex]"))
        #expect(output.contains("[Gemini]"))
    }

    @Test("every workspace is listed with its path, pinned or not")
    func listsEveryWorkspaceWithPath() {
        let workspaces = [
            EnvironmentStore.WorkspaceListing(name: "work", path: URL(fileURLWithPath: "/tmp/work")),
            EnvironmentStore.WorkspaceListing(name: "empty", path: URL(fileURLWithPath: "/tmp/empty")),
        ]
        let output = SandboxCommand.List.render(workspaces: workspaces, accountsByTool: [:], originPath: originPath)
        #expect(output.contains("work: /tmp/work"))
        #expect(output.contains("empty: /tmp/empty"))
        #expect(output.contains("origin: /tmp/origin"))
    }

    @Test("only prints '+ pinned:' for a workspace that actually has an account of that tool")
    func pinnedOnlyWhenAccountExists() {
        let workspaces = [EnvironmentStore.WorkspaceListing(name: "work", path: URL(fileURLWithPath: "/tmp/work"))]
        let acct = Account(tool: .claude, displayName: "grady", email: "grady@example.com", plan: "pro", workspace: "work")
        let output = SandboxCommand.List.render(
            workspaces: workspaces, accountsByTool: [.claude: [acct]], originPath: originPath)

        // Claude's "work" block has the pinned account...
        let claudeSection = output.components(separatedBy: "[Codex]")[0]
        #expect(claudeSection.contains("+ pinned:"))
        #expect(claudeSection.contains("- grady (grady@example.com, pro)"))

        // ...but Codex/Gemini have no accounts at all, so neither section
        // prints a pinned block for "work" or "origin".
        #expect(!output.contains("[Codex]\norigin: /tmp/origin\n  "))
    }

    @Test("multiple accounts of the same tool can be pinned to the same workspace")
    func multipleAccountsPerWorkspace() {
        let workspaces = [EnvironmentStore.WorkspaceListing(name: "shared", path: URL(fileURLWithPath: "/tmp/shared"))]
        let accounts = [
            Account(tool: .claude, displayName: "alice", workspace: "shared"),
            Account(tool: .claude, displayName: "bob", workspace: "shared"),
        ]
        let output = SandboxCommand.List.render(
            workspaces: workspaces, accountsByTool: [.claude: accounts], originPath: originPath)
        #expect(output.contains("- alice"))
        #expect(output.contains("- bob"))
    }

    @Test("account with no email/plan prints just the display name, no empty parens")
    func accountWithNoInfoOmitsParens() {
        let workspaces = [EnvironmentStore.WorkspaceListing(name: "work", path: URL(fileURLWithPath: "/tmp/work"))]
        let acct = Account(tool: .claude, displayName: "grady", workspace: "work")
        let output = SandboxCommand.List.render(
            workspaces: workspaces, accountsByTool: [.claude: [acct]], originPath: originPath)
        #expect(output.contains("- grady\n") || output.hasSuffix("- grady"))
        #expect(!output.contains("- grady ("))
    }
}
