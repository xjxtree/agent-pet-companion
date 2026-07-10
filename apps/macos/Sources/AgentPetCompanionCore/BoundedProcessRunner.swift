import Darwin
import Foundation

public enum BoundedProcessTermination: Equatable, Sendable {
    case exited(status: Int32)
    case timedOut
}

public struct BoundedProcessResult: Equatable, Sendable {
    public let termination: BoundedProcessTermination
    public let standardOutput: Data
    public let standardError: Data

    public init(
        termination: BoundedProcessTermination,
        standardOutput: Data,
        standardError: Data
    ) {
        self.termination = termination
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum BoundedProcessRunnerError: Error, LocalizedError, Sendable {
    case invalidTimeout
    case launchFailed(String)
    case terminationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidTimeout:
            "Process timeout must be greater than zero."
        case let .launchFailed(message):
            "Could not launch process: \(message)"
        case .terminationFailed:
            "Process did not terminate within the cleanup deadline."
        }
    }
}

public enum BoundedProcessRunner {
    public static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: Duration,
        outputLimit: Int = 64 * 1_024
    ) async throws -> BoundedProcessResult {
        let timeoutSeconds = timeout.boundedProcessTimeInterval
        guard timeoutSeconds > 0 else {
            throw BoundedProcessRunnerError.invalidTimeout
        }
        let operation = BoundedProcessOperation(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            timeout: timeoutSeconds,
            outputLimit: max(0, outputLimit)
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try operation.run())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }
}

private final class BoundedProcessOperation: @unchecked Sendable {
    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]?
    private let timeout: TimeInterval
    private let outputLimit: Int
    private let stateLock = NSLock()
    private var cancelled = false
    private var finished = false

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval,
        outputLimit: Int
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
        self.outputLimit = outputLimit
    }

    func cancel() {
        stateLock.lock()
        if !finished {
            cancelled = true
        }
        stateLock.unlock()
    }

    func run() throws -> BoundedProcessResult {
        defer {
            stateLock.lock()
            finished = true
            stateLock.unlock()
        }
        try throwIfCancelled()

        let process = Process()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }
        do {
            try process.run()
        } catch {
            throw BoundedProcessRunnerError.launchFailed(error.localizedDescription)
        }

        let outputSink = BoundedDataSink(limit: outputLimit)
        let errorSink = BoundedDataSink(limit: outputLimit)
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            drain(standardOutputPipe.fileHandleForReading, into: outputSink)
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            drain(standardErrorPipe.fileHandleForReading, into: errorSink)
            drainGroup.leave()
        }

        let deadline = DispatchTime.now() + timeout
        var didTimeOut = false
        var wasCancelled = false
        while true {
            if isCancelled {
                wasCancelled = true
                break
            }
            let now = DispatchTime.now()
            if now >= deadline {
                didTimeOut = true
                break
            }
            let nextPoll = min(deadline, now + .milliseconds(20))
            if termination.wait(timeout: nextPoll) == .success {
                break
            }
        }

        if didTimeOut || wasCancelled {
            try terminate(process, termination: termination)
        }

        if drainGroup.wait(timeout: .now() + .seconds(1)) == .timedOut {
            try? standardOutputPipe.fileHandleForReading.close()
            try? standardErrorPipe.fileHandleForReading.close()
            guard drainGroup.wait(timeout: .now() + .milliseconds(250)) == .success else {
                throw BoundedProcessRunnerError.terminationFailed
            }
        }

        if wasCancelled {
            throw CancellationError()
        }
        let terminationReason: BoundedProcessTermination = didTimeOut
            ? .timedOut
            : .exited(status: process.terminationStatus)
        return BoundedProcessResult(
            termination: terminationReason,
            standardOutput: outputSink.data,
            standardError: errorSink.data
        )
    }

    private var isCancelled: Bool {
        stateLock.lock()
        let value = cancelled
        stateLock.unlock()
        return value
    }

    private func throwIfCancelled() throws {
        if isCancelled {
            throw CancellationError()
        }
    }

    private func terminate(_ process: Process, termination: DispatchSemaphore) throws {
        if process.isRunning {
            process.terminate()
        }
        if process.isRunning, termination.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        if process.isRunning,
           termination.wait(timeout: .now() + .seconds(1)) == .timedOut,
           process.isRunning {
            throw BoundedProcessRunnerError.terminationFailed
        }
    }
}

private final class BoundedDataSink: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var storage = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard storage.count < limit else { return }
        storage.append(data.prefix(limit - storage.count))
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private func drain(_ handle: FileHandle, into sink: BoundedDataSink) {
    defer { try? handle.close() }
    while true {
        do {
            guard let data = try handle.read(upToCount: 4_096), !data.isEmpty else { return }
            sink.append(data)
        } catch {
            return
        }
    }
}

private extension Duration {
    var boundedProcessTimeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
