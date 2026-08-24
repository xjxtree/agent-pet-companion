import Foundation
import Testing
@testable import AgentPetCompanionCore

@Suite
struct BoundedConcurrencyGateTests {
    @Test
    func neverAdmitsMoreThanTheLimit() async throws {
        let limit = 3
        let gate = BoundedConcurrencyGate(limit: limit)
        let tracker = ConcurrencyTracker()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await gate.withPermit {
                        tracker.enter()
                        await Task.yield()
                        tracker.exit()
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(tracker.observedPeak <= limit)
        #expect(tracker.totalEntries == 20)
    }

    @Test
    func releasesPermitsWhenIdle() async throws {
        let gate = BoundedConcurrencyGate(limit: 1)
        try await gate.wait()
        gate.signal()
        // The recycled permit must admit a new waiter immediately.
        try await gate.wait()
        gate.signal()
    }

    @Test
    func cancellingQueuedWorkRemovesItBeforeTheOperationStarts() async throws {
        let gate = BoundedConcurrencyGate(limit: 1)
        let tracker = ConcurrencyTracker()
        try await gate.wait()

        let queued = Task {
            try await gate.withPermit {
                tracker.enter()
                tracker.exit()
            }
        }
        for _ in 0..<1_000 where gate.queuedWaiterCount == 0 {
            await Task.yield()
        }
        #expect(gate.queuedWaiterCount == 1)

        queued.cancel()
        do {
            try await queued.value
            Issue.record("Expected queued work to be cancelled")
        } catch PetCoreTransportError.cancelled {
            // Expected.
        }

        #expect(gate.queuedWaiterCount == 0)
        #expect(tracker.totalEntries == 0)

        gate.signal()
        try await gate.withPermit {
            tracker.enter()
            tracker.exit()
        }
        #expect(tracker.totalEntries == 1)
    }
}

/// Counts overlapping critical sections without blocking threads.
private final class ConcurrencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var observedPeak = 0
    private(set) var totalEntries = 0

    func enter() {
        lock.lock()
        current += 1
        totalEntries += 1
        observedPeak = max(observedPeak, current)
        lock.unlock()
    }

    func exit() {
        lock.lock()
        current -= 1
        lock.unlock()
    }
}
