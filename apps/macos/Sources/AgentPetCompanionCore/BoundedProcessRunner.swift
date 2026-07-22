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

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        let processIdentifier = try spawnProcessGroup(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            standardOutputPipe: standardOutputPipe,
            standardErrorPipe: standardErrorPipe
        )

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
        var waitStatus: Int32?
        while true {
            if let status = try pollWaitStatus(for: processIdentifier) {
                waitStatus = status
                break
            }
            if isCancelled {
                wasCancelled = true
                break
            }
            let now = DispatchTime.now()
            if now >= deadline {
                didTimeOut = true
                break
            }
            let remaining = Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds)
                / 1_000_000_000
            Thread.sleep(forTimeInterval: min(0.02, remaining))
        }

        if didTimeOut || wasCancelled {
            waitStatus = try terminateProcessGroup(
                processIdentifier,
                initialWaitStatus: waitStatus
            )
        } else if processGroupExists(processIdentifier) {
            // The direct child may exit after starting background work that no
            // longer owns either output pipe. Preserve the leader's wait status
            // while still draining every remaining member of this operation's
            // private process group before returning.
            waitStatus = try terminateProcessGroup(
                processIdentifier,
                initialWaitStatus: waitStatus
            )
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
            : .exited(status: Self.terminationStatus(from: waitStatus ?? 0))
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

    private func terminateProcessGroup(
        _ processIdentifier: pid_t,
        initialWaitStatus: Int32?
    ) throws -> Int32 {
        var waitStatus = initialWaitStatus

        // `spawnProcessGroup` makes the direct child the leader of a process
        // group owned by this operation. Signals sent to the negative PGID
        // therefore reach the command and every descendant it started, without
        // relying on Foundation.Process's launcher PID or enumerating unrelated
        // processes.
        try signalProcessGroup(processIdentifier, signal: SIGTERM)
        if try waitForProcessGroupExit(
            processIdentifier,
            waitStatus: &waitStatus,
            deadline: .now() + .milliseconds(250)
        ) {
            return waitStatus ?? 0
        }

        try signalProcessGroup(processIdentifier, signal: SIGKILL)
        guard try waitForProcessGroupExit(
            processIdentifier,
            waitStatus: &waitStatus,
            deadline: .now() + .seconds(1)
        ), let waitStatus else {
            throw BoundedProcessRunnerError.terminationFailed
        }
        return waitStatus
    }

    private func waitForProcessGroupExit(
        _ processIdentifier: pid_t,
        waitStatus: inout Int32?,
        deadline: DispatchTime
    ) throws -> Bool {
        while true {
            if waitStatus == nil {
                waitStatus = try pollWaitStatus(for: processIdentifier)
            }
            if !processGroupExists(processIdentifier), waitStatus != nil {
                return true
            }
            guard DispatchTime.now() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func pollWaitStatus(for processIdentifier: pid_t) throws -> Int32? {
        while true {
            var status: Int32 = 0
            let result = Darwin.waitpid(processIdentifier, &status, WNOHANG)
            if result == processIdentifier {
                return status
            }
            if result == 0 {
                return nil
            }
            if errno == EINTR {
                continue
            }
            throw BoundedProcessRunnerError.terminationFailed
        }
    }

    private func processGroupExists(_ processGroupIdentifier: pid_t) -> Bool {
        if Darwin.kill(-processGroupIdentifier, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }

    private func signalProcessGroup(_ processGroupIdentifier: pid_t, signal: Int32) throws {
        guard Darwin.kill(-processGroupIdentifier, signal) != 0 else { return }
        guard errno == ESRCH else {
            throw BoundedProcessRunnerError.terminationFailed
        }
    }

    private static func terminationStatus(from waitStatus: Int32) -> Int32 {
        let terminatingSignal = waitStatus & 0x7f
        if terminatingSignal == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return terminatingSignal
    }
}

private func spawnProcessGroup(
    executableURL: URL,
    arguments: [String],
    environment: [String: String]?,
    standardOutputPipe: Pipe,
    standardErrorPipe: Pipe
) throws -> pid_t {
    var fileActions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    var fileActionsInitialized = false
    var attributesInitialized = false

    defer {
        if attributesInitialized {
            posix_spawnattr_destroy(&attributes)
        }
        if fileActionsInitialized {
            posix_spawn_file_actions_destroy(&fileActions)
        }
    }

    try checkSpawnCall(posix_spawn_file_actions_init(&fileActions))
    fileActionsInitialized = true
    try checkSpawnCall(posix_spawnattr_init(&attributes))
    attributesInitialized = true

    let outputReadDescriptor = standardOutputPipe.fileHandleForReading.fileDescriptor
    let outputWriteDescriptor = standardOutputPipe.fileHandleForWriting.fileDescriptor
    let errorReadDescriptor = standardErrorPipe.fileHandleForReading.fileDescriptor
    let errorWriteDescriptor = standardErrorPipe.fileHandleForWriting.fileDescriptor

    try checkSpawnCall(posix_spawn_file_actions_adddup2(
        &fileActions,
        outputWriteDescriptor,
        STDOUT_FILENO
    ))
    try checkSpawnCall(posix_spawn_file_actions_adddup2(
        &fileActions,
        errorWriteDescriptor,
        STDERR_FILENO
    ))
    for descriptor in [
        outputReadDescriptor,
        outputWriteDescriptor,
        errorReadDescriptor,
        errorWriteDescriptor
    ] where descriptor != STDOUT_FILENO && descriptor != STDERR_FILENO {
        try checkSpawnCall(posix_spawn_file_actions_addclose(&fileActions, descriptor))
    }

    try checkSpawnCall(posix_spawnattr_setflags(
        &attributes,
        Int16(POSIX_SPAWN_SETPGROUP)
    ))
    // A pgroup value of zero makes the spawned child's PID its PGID.
    try checkSpawnCall(posix_spawnattr_setpgroup(&attributes, 0))

    let executablePath = executableURL.path
    var argumentPointers = try makeCStringArray([executablePath] + arguments)
    let inheritedEnvironment = environment ?? ProcessInfo.processInfo.environment
    var environmentPointers = try makeCStringArray(
        inheritedEnvironment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
    )
    defer {
        freeCStringArray(&argumentPointers)
        freeCStringArray(&environmentPointers)
    }

    var processIdentifier: pid_t = 0
    let spawnResult = executablePath.withCString { executablePointer in
        argumentPointers.withUnsafeMutableBufferPointer { argumentBuffer in
            environmentPointers.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(
                    &processIdentifier,
                    executablePointer,
                    &fileActions,
                    &attributes,
                    argumentBuffer.baseAddress,
                    environmentBuffer.baseAddress
                )
            }
        }
    }
    guard spawnResult == 0 else {
        try? standardOutputPipe.fileHandleForReading.close()
        try? standardErrorPipe.fileHandleForReading.close()
        try? standardOutputPipe.fileHandleForWriting.close()
        try? standardErrorPipe.fileHandleForWriting.close()
        throw BoundedProcessRunnerError.launchFailed(spawnErrorDescription(spawnResult))
    }

    // Only the child may retain the write ends. Closing them in the parent lets
    // the drain tasks observe EOF after the complete process group exits.
    try? standardOutputPipe.fileHandleForWriting.close()
    try? standardErrorPipe.fileHandleForWriting.close()
    return processIdentifier
}

private func checkSpawnCall(_ result: Int32) throws {
    guard result == 0 else {
        throw BoundedProcessRunnerError.launchFailed(spawnErrorDescription(result))
    }
}

private func spawnErrorDescription(_ error: Int32) -> String {
    String(cString: strerror(error))
}

private func makeCStringArray(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
    var pointers: [UnsafeMutablePointer<CChar>?] = []
    pointers.reserveCapacity(strings.count + 1)
    for string in strings {
        guard let pointer = strdup(string) else {
            freeCStringArray(&pointers)
            throw BoundedProcessRunnerError.launchFailed("Could not allocate process arguments.")
        }
        pointers.append(pointer)
    }
    pointers.append(nil)
    return pointers
}

private func freeCStringArray(_ pointers: inout [UnsafeMutablePointer<CChar>?]) {
    for pointer in pointers {
        free(pointer)
    }
    pointers.removeAll(keepingCapacity: false)
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
