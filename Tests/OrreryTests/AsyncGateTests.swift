import Foundation
import Testing
@testable import OrreryCore

/// Proves the property the whole test-helper migration rests on: that two
/// bodies never overlap.
///
/// Worth its own test because the obvious implementation does not have it.
/// Swift actors are **reentrant**: an actor-isolated function that suspends lets
/// the actor process other calls, so marking a helper `@globalActor` serializes
/// the *entry* and not the body across an `await`. Two captures would still
/// interleave — rarely, under load — which is the failure mode this repo keeps
/// paying for.
@Suite("AsyncGate")
struct AsyncGateTests {

    /// Records overlap by counting how many bodies are inside at once.
    private actor Occupancy {
        private(set) var peak = 0
        private var current = 0
        func enter() { current += 1; peak = max(peak, current) }
        func leave() { current -= 1 }
    }

    @Test("bodies never overlap, however many ask at once")
    func bodiesAreSerialized() async {
        let gate = AsyncGate()
        let occupancy = Occupancy()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    await gate.withGate {
                        await occupancy.enter()
                        // A real suspension inside the body — the exact point a
                        // reentrant actor would let someone else in.
                        try? await Task.sleep(for: .milliseconds(2))
                        await occupancy.leave()
                    }
                }
            }
        }

        #expect(await occupancy.peak == 1, "two bodies were inside the gate at once")
    }

    @Test("every waiter is eventually let in")
    func noWaiterIsStranded() async {
        let gate = AsyncGate()
        let counter = Occupancy()
        var completed = 0

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await gate.withGate {
                        await counter.enter()
                        await counter.leave()
                    }
                }
            }
            for await _ in group { completed += 1 }
        }

        #expect(completed == 10)
    }

    /// A body that throws must still release, or the first failing test wedges
    /// every later one that needs the same gate — a far worse symptom than the
    /// original failure.
    @Test("a throwing body releases the gate")
    func throwingBodyReleases() async throws {
        struct Boom: Error {}
        let gate = AsyncGate()

        await #expect(throws: Boom.self) {
            try await gate.withGate { throw Boom() }
        }

        // If the throw had leaked the gate this would never return.
        var ran = false
        await gate.withGate { ran = true }
        #expect(ran)
    }

    @Test("a cancelled caller does not wedge the gate")
    func cancellationDoesNotWedge() async throws {
        let gate = AsyncGate()

        // Hold the gate, queue a waiter behind it, cancel the waiter, release.
        let holder = Task { await gate.withGate { try? await Task.sleep(for: .milliseconds(80)) } }
        try await Task.sleep(for: .milliseconds(10))
        let waiter = Task { await gate.withGate {} }
        try await Task.sleep(for: .milliseconds(10))
        waiter.cancel()
        _ = await holder.value
        _ = await waiter.value

        var ran = false
        await gate.withGate { ran = true }
        #expect(ran, "the gate is still usable after a waiter was cancelled")
    }
}
