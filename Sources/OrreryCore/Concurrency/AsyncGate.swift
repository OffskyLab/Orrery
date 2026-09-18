import Foundation

/// Mutual exclusion that holds across `await`.
///
/// ## Why a global actor will not do
///
/// Swift actors are **reentrant**: an actor-isolated function that suspends
/// releases the actor, which then processes other calls. So annotating a helper
/// `@globalActor` serializes its *entry* and not its body — two callers still
/// interleave at every `await` inside. For a helper that redirects a
/// process-wide file descriptor or swaps a process-wide environment variable,
/// that is no protection at all, and the failure is intermittent: it shows up
/// under load, in a full run, never when the test is run alone.
///
/// ## Why not a lock or a semaphore
///
/// `NSLock` is thread-owned, and after a suspension the continuation may resume
/// on a different thread — unlocking from there is undefined behaviour. Swift 6
/// makes `DispatchSemaphore.wait()` unavailable from an async context outright,
/// because blocking a cooperative thread can deadlock the pool that would have
/// completed the work being waited on.
///
/// So: an explicit queue of waiters, resumed one at a time.
public actor AsyncGate {
    private var isHeld = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Runs `body` with no other body inside the gate.
    ///
    /// Releases on the way out whether `body` returned or threw. A gate leaked
    /// by a throwing body would wedge every later caller — a far worse symptom
    /// than whatever failed first, and one that would look like a hang rather
    /// than a failure.
    /// `nonisolated` on purpose: only the bookkeeping belongs to this actor. The
    /// body runs in its caller's isolation, which is both what callers expect and
    /// what lets a non-`Sendable` closure through — handing one to an
    /// actor-isolated method is a data race Swift 6 refuses outright.
    public nonisolated func withGate<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        do {
            let value = try await body()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }

    private func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the gate straight to the next waiter rather than clearing `isHeld`
    /// and letting them race for it: the queue is the fairness guarantee, and a
    /// gap between release and re-acquire is where a third caller would cut in.
    private func release() {
        if waiting.isEmpty {
            isHeld = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
