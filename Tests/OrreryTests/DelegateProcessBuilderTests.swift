import Testing
import Foundation
@testable import OrreryCore

/// Confirms `DelegateProcessBuilder.build()` strips IPC / supervision
/// variables that must never leak into a delegated (throwaway) child
/// process — mirroring the same strip performed by `RunCommand`,
/// `MCPSetupCommand`, and `ToolSetup`.
@Suite("DelegateProcessBuilder")
struct DelegateProcessBuilderTests {
    private func makeStore() throws -> (store: EnvironmentStore, tmp: URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-delegate-builder-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (EnvironmentStore(homeURL: tmp), tmp)
    }

    @Test("strips CLAUDECODE and ORRERY_PHANTOM_ID from the built process environment")
    func stripsIPCAndPhantomVars() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let savedClaudecode = ProcessInfo.processInfo.environment["CLAUDECODE"]
        let savedPhantomId = ProcessInfo.processInfo.environment["ORRERY_PHANTOM_ID"]
        setenv("CLAUDECODE", "1", 1)
        setenv("ORRERY_PHANTOM_ID", "outer-supervisor-id", 1)
        defer {
            if let savedClaudecode { setenv("CLAUDECODE", savedClaudecode, 1) }
            else { unsetenv("CLAUDECODE") }
            if let savedPhantomId { setenv("ORRERY_PHANTOM_ID", savedPhantomId, 1) }
            else { unsetenv("ORRERY_PHANTOM_ID") }
        }

        let builder = DelegateProcessBuilder(
            tool: .claude, prompt: "hello", resumeSessionId: nil,
            environment: nil, store: store)
        let (process, _, _) = try builder.build()

        let env = process.environment ?? [:]
        #expect(env["CLAUDECODE"] == nil)
        #expect(env["ORRERY_PHANTOM_ID"] == nil)
    }
}
