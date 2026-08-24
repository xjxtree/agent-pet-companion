import Foundation
import Testing
@testable import AgentPetCompanionCore

@Suite
struct BoundedConcurrencyGateTests {
    @Test
    func neverAdmitsMoreThanTheLimit() async {
        let limit = 3
        let gate = BoundedConcurrencyGate(limit: limit)
        let tracker = ConcurrencyTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await gate.wait()
                    defer { gate.signal() }
                    tracker.enter()
                    await Task.yield()
                    tracker.exit()
                }
            }
        }

        #expect(tracker.observedPeak <= limit)
        #expect(tracker.totalEntries == 20)
    }

    @Test
    func releasesPermitsWhenIdle() async {
        let gate = BoundedConcurrencyGate(limit: 1)
        await gate.wait()
        gate.signal()
        // The recycled permit must admit a new waiter immediately.
        await gate.wait()
        gate.signal()
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
