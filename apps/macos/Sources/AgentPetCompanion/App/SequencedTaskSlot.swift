import Foundation

/// One running `@MainActor` task slot guarded by a monotonic sequence.
///
/// This is the shared form of the "join the in-flight operation, start it
/// exactly once, and let only the current owner clear the slot" idiom that
/// service bootstrap and recovery both use. Callers `await run(...)`; a
/// concurrent caller joins the already-running task instead of starting a
/// second one, and a finished task clears the slot only when no newer run
/// has replaced it in the meantime.
@MainActor
final class SequencedTaskSlot<Success: Sendable> {
    private var sequence: UInt64 = 0
    private var running: (id: UInt64, task: Task<Success, Never>)?

    var isRunning: Bool { running != nil }

    /// Joins the in-flight task when one exists.
    func joinExisting() async -> Success? {
        await running?.task.value
    }

    /// Starts `operation` unless one is already running, awaits it, and
    /// clears the slot only if no newer run superseded this one.
    func run(operation: @escaping @MainActor () async -> Success) async -> Success {
        if let running {
            return await running.task.value
        }
        sequence &+= 1
        let id = sequence
        let task = Task { @MainActor in
            await operation()
        }
        running = (id, task)
        let success = await task.value
        if running?.id == id {
            running = nil
        }
        return success
    }
}
