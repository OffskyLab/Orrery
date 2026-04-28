import XCTest
@testable import OrreryCore

/// Smoke tests for `ProcessAgentExecutor` — the concrete conformance of
/// `AgentExecutor` that wraps `DelegateProcessBuilder`.
///
/// The full end-to-end behavior (drain / timeout / session diff) is
/// exercised by the Magi orchestrator integration tests that spawn real
/// delegate CLIs. These tests focus on shape + safety invariants that
/// don't require a working tool binary on $PATH.
final class ProcessAgentExecutorTests: XCTestCase {

    private func makeStore() throws -> (EnvironmentStore, URL) {
        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orrery-exec-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmpHome, withIntermediateDirectories: true)
        let store = EnvironmentStore(homeURL: tmpHome)
        return (store, tmpHome)
    }

    func testExecutorConformsToAgentExecutorProtocol() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let exec: AgentExecutor = ProcessAgentExecutor(
            cwd: tmp.path, store: store, activeEnvironment: nil
        )
        // If this compiles and runs, the polymorphic protocol usage works.
        XCTAssertNotNil(exec)
    }

    func testCancelBeforeExecuteIsSafeNoOp() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let exec = ProcessAgentExecutor(
            cwd: tmp.path, store: store, activeEnvironment: nil
        )
        // Must not crash / deadlock even though no process is inflight.
        exec.cancel()
        exec.cancel()
    }

    func testCancelIsIdempotentAcrossThreads() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let exec = ProcessAgentExecutor(
            cwd: tmp.path, store: store, activeEnvironment: nil
        )
        // Hammer cancel() from many threads — lock guards currentProcess.
        let group = DispatchGroup()
        for _ in 0..<32 {
            group.enter()
            DispatchQueue.global().async {
                exec.cancel()
                group.leave()
            }
        }
        group.wait()
    }
}
