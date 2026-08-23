import Testing
@testable import AgentPetCompanion

@MainActor
struct SequencedTaskSlotTests {
    @Test
    func slotIsRunningDuringOperationAndClearsAfterwards() async {
        let slot = SequencedTaskSlot<Int>()
        let gate = AsyncGate()

        async let value: Int = slot.run {
            await gate.wait()
            return 41
        }
        var yields = 0
        while !slot.isRunning {
            await Task.yield()
            yields &+= 1
            #expect(yields < 100_000, "operation never started")
        }
        #expect(slot.isRunning)

        gate.open()
        #expect(await value == 41)
        #expect(slot.isRunning == false)
    }

    @Test
    func joinExistingAwaitsTheRunningTaskOnceStarted() async {
        let slot = SequencedTaskSlot<Int>()
        let gate = AsyncGate()

        async let value: Int = slot.run {
            await gate.wait()
            return 7
        }
        var yields = 0
        while !slot.isRunning {
            await Task.yield()
            yields &+= 1
            #expect(yields < 100_000, "operation never started")
        }

        async let joined: Int? = slot.joinExisting()
        gate.open()
        #expect(await value == 7)
        #expect(await joined == 7)
        #expect(slot.isRunning == false)
    }

    @Test
    func joinExistingReturnsNilWhenIdle() async {
        let slot = SequencedTaskSlot<Bool>()
        #expect(await slot.joinExisting() == nil)
    }

    @Test
    func slotRunsAgainAfterCompletion() async {
        let slot = SequencedTaskSlot<Int>()

        let first = await slot.run { 1 }
        #expect(first == 1)
        #expect(slot.isRunning == false)

        let second = await slot.run { 2 }
        #expect(second == 2)
        #expect(slot.isRunning == false)
    }
}

/// A one-shot async gate: `wait` suspends until `open`, and stays open for
/// every later waiter.
@MainActor
private final class AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        isOpen = true
        let resumed = waiters
        waiters = []
        resumed.forEach { $0.resume() }
    }
}
