import AgentPetCompanionCore
import Darwin
import Foundation

@main
struct AgentPetCompanionTransportValidation {
    private typealias Validation = () async throws -> Void

    static func main() async {
        let validations: [(String, Validation)] = [
            ("request_times_out", requestTimesOut),
            ("task_cancellation_closes_connection", taskCancellationClosesConnection),
            ("partial_response_does_not_block_main_actor", partialResponseDoesNotBlockMainActor),
            ("healthy_service_skips_launchctl", healthyServiceSkipsLaunchctl),
            ("missing_service_bootstraps_once", missingServiceBootstrapsOnce),
            ("concurrent_bootstrap_calls_coalesce", concurrentBootstrapCallsCoalesce),
            ("app_bootstrap_retries_with_bounded_backoff", appBootstrapRetriesWithBoundedBackoff),
            ("app_bootstrap_resets_after_terminal_failure", appBootstrapResetsAfterTerminalFailure),
            ("app_bootstrap_calls_coalesce", appBootstrapCallsCoalesce),
            ("app_recovery_rechecks_and_coalesces", appRecoveryRechecksAndCoalesces),
            ("process_output_and_timeout_are_bounded", processOutputAndTimeoutAreBounded),
            ("process_cancellation_is_bounded", processCancellationIsBounded),
            ("process_ignoring_term_is_killed_within_bound", processIgnoringTermIsKilledWithinBound)
        ]

        var failureCount = 0
        for (name, validation) in validations {
            do {
                try await validation()
                print("PASS \(name)")
            } catch {
                failureCount += 1
                fputs("FAIL \(name): \(error.localizedDescription)\n", stderr)
            }
        }

        if failureCount > 0 {
            exit(EXIT_FAILURE)
        }
        print("PASS transport_and_startup_validation")
    }

    private static func requestTimesOut() async throws {
        let server = try UnixSocketValidationServer { client in
            _ = readRequestLine(from: client)
            waitForPeerToClose(client)
        }
        let transport = PetCoreTransport(socketPath: server.socketPath)

        do {
            _ = try await transport.request(
                method: "petcore.health",
                params: Data("{}".utf8),
                timeout: .milliseconds(100)
            )
            throw ValidationFailure("request completed instead of timing out")
        } catch PetCoreTransportError.timedOut {
            return
        }
    }

    private static func taskCancellationClosesConnection() async throws {
        let requestReceived = DispatchSemaphore(value: 0)
        let peerClosed = DispatchSemaphore(value: 0)
        let server = try UnixSocketValidationServer { client in
            _ = readRequestLine(from: client)
            requestReceived.signal()
            waitForPeerToClose(client)
            peerClosed.signal()
        }
        let transport = PetCoreTransport(socketPath: server.socketPath)
        let request = Task {
            try await transport.request(
                method: "state.wait",
                params: Data("{}".utf8),
                timeout: .seconds(5)
            )
        }

        guard await waitForSemaphore(requestReceived) else {
            throw ValidationFailure("server did not receive the request")
        }
        request.cancel()
        do {
            _ = try await request.value
            throw ValidationFailure("cancelled request completed successfully")
        } catch is CancellationError {
            // Accepted.
        } catch PetCoreTransportError.cancelled {
            // The transport may normalize cancellation at its boundary.
        }
        guard await waitForSemaphore(peerClosed) else {
            throw ValidationFailure("cancellation did not close the client connection")
        }
    }

    @MainActor
    private static func partialResponseDoesNotBlockMainActor() async throws {
        let partialResponseWritten = DispatchSemaphore(value: 0)
        let server = try UnixSocketValidationServer { client in
            _ = readRequestLine(from: client)
            writeAll(
                Data("{\"jsonrpc\":\"2.0\",\"id\":\"swift\",\"result\":{\"status\":\"".utf8),
                to: client
            )
            partialResponseWritten.signal()
            usleep(150_000)
            writeAll(Data("healthy\"}}\n".utf8), to: client)
        }
        let transport = PetCoreTransport(socketPath: server.socketPath)
        let request = Task {
            try await transport.request(
                method: "petcore.health",
                params: Data("{}".utf8),
                timeout: .seconds(1)
            )
        }

        guard await waitForSemaphore(partialResponseWritten) else {
            throw ValidationFailure("server did not write the partial response")
        }
        let mainActorProbe = Task { @MainActor in true }
        guard await mainActorProbe.value else {
            throw ValidationFailure("main actor probe did not run")
        }
        let response = try await request.value
        guard String(decoding: response, as: UTF8.self).contains("healthy") else {
            throw ValidationFailure("transport returned the wrong response")
        }
    }

    private static func healthyServiceSkipsLaunchctl() async throws {
        let probe = ServiceStartupProbe(healthResponses: [true])
        let manager = makeManager(probe: probe)

        guard await manager.ensureRunning() == .alreadyHealthy else {
            throw ValidationFailure("healthy service was not recognized")
        }
        let counts = await probe.counts()
        guard counts.launchctl == 0, counts.direct == 0 else {
            throw ValidationFailure("healthy service invoked a startup runner")
        }
    }

    private static func missingServiceBootstrapsOnce() async throws {
        let probe = ServiceStartupProbe(healthResponses: [false, true])
        let manager = makeManager(probe: probe)

        guard await manager.ensureRunning() == .started else {
            throw ValidationFailure("missing service did not start")
        }
        let counts = await probe.counts()
        guard counts.launchctl == 1, counts.direct == 0 else {
            throw ValidationFailure("missing service did not bootstrap exactly once")
        }
    }

    private static func concurrentBootstrapCallsCoalesce() async throws {
        let probe = ServiceStartupProbe(
            healthResponses: [false, true],
            launchDelay: .milliseconds(100)
        )
        let manager = makeManager(probe: probe)

        async let first = manager.ensureRunning()
        async let second = manager.ensureRunning()
        let results = await [first, second]
        guard results == [.started, .started] else {
            throw ValidationFailure("concurrent callers did not share the startup result")
        }
        let counts = await probe.counts()
        guard counts.launchctl == 1, counts.direct == 0 else {
            throw ValidationFailure("concurrent callers launched more than once")
        }
    }

    private static func makeManager(probe: ServiceStartupProbe) -> PetCoreServiceStartupCoordinator {
        PetCoreServiceStartupCoordinator(
            healthCheck: { await probe.healthCheck() },
            launchctlRunner: { try await probe.runLaunchctl() },
            directRunner: { try await probe.runDirect() },
            healthCheckAttempts: 1,
            sleep: { _ in }
        )
    }

    private static func appBootstrapRetriesWithBoundedBackoff() async throws {
        let probe = AppBootstrapProbe(results: [
            .failed(reason: "first"),
            .failed(reason: "second"),
            .started
        ])
        let coordinator = PetCoreAppBootstrapCoordinator(
            ensureRunning: { await probe.nextResult() },
            policy: ServiceBootstrapRetryPolicy(
                maximumAttempts: 4,
                initialDelay: .milliseconds(10),
                maximumDelay: .milliseconds(20)
            ),
            sleep: { duration in await probe.recordSleep(duration) }
        )

        guard await coordinator.ensureRunning() == .started else {
            throw ValidationFailure("transient bootstrap failure did not recover")
        }
        let snapshot = await probe.snapshot()
        guard snapshot.attempts == 3 else {
            throw ValidationFailure("bootstrap did not use the expected attempt count")
        }
        guard snapshot.delays == [.milliseconds(10), .milliseconds(20)] else {
            throw ValidationFailure("bootstrap backoff was not bounded exponential backoff")
        }
    }

    private static func appBootstrapResetsAfterTerminalFailure() async throws {
        let probe = AppBootstrapProbe(results: [
            .failed(reason: "first"),
            .failed(reason: "second"),
            .started
        ])
        let coordinator = PetCoreAppBootstrapCoordinator(
            ensureRunning: { await probe.nextResult() },
            policy: ServiceBootstrapRetryPolicy(
                maximumAttempts: 2,
                initialDelay: .milliseconds(1),
                maximumDelay: .milliseconds(1)
            ),
            sleep: { duration in await probe.recordSleep(duration) }
        )

        guard case .failed = await coordinator.ensureRunning() else {
            throw ValidationFailure("terminal bootstrap failure was not surfaced")
        }
        guard await coordinator.ensureRunning() == .started else {
            throw ValidationFailure("bootstrap did not reset after terminal failure")
        }
        guard await probe.snapshot().attempts == 3 else {
            throw ValidationFailure("bootstrap retry cycle did not restart cleanly")
        }
    }

    private static func appBootstrapCallsCoalesce() async throws {
        let probe = AppBootstrapProbe(results: [.started], resultDelay: .milliseconds(100))
        let coordinator = PetCoreAppBootstrapCoordinator(
            ensureRunning: { await probe.nextResult() },
            policy: ServiceBootstrapRetryPolicy(
                maximumAttempts: 2,
                initialDelay: .milliseconds(1),
                maximumDelay: .milliseconds(1)
            ),
            sleep: { _ in }
        )

        async let first = coordinator.ensureRunning()
        async let second = coordinator.ensureRunning()
        guard await [first, second] == [.started, .started] else {
            throw ValidationFailure("concurrent app bootstrap callers did not share a result")
        }
        guard await probe.snapshot().attempts == 1 else {
            throw ValidationFailure("concurrent app bootstrap callers ran duplicate attempts")
        }
    }

    private static func appRecoveryRechecksAndCoalesces() async throws {
        let probe = AppBootstrapProbe(
            results: [.started, .alreadyHealthy],
            resultDelay: .milliseconds(100)
        )
        let coordinator = PetCoreAppBootstrapCoordinator(
            ensureRunning: { await probe.nextResult() },
            policy: ServiceBootstrapRetryPolicy(
                maximumAttempts: 2,
                initialDelay: .milliseconds(1),
                maximumDelay: .milliseconds(1)
            ),
            sleep: { _ in }
        )

        guard await coordinator.ensureRunning() == .started else {
            throw ValidationFailure("initial app bootstrap did not complete")
        }
        async let first = coordinator.recover()
        async let second = coordinator.recover()
        guard await [first, second] == [.alreadyHealthy, .alreadyHealthy] else {
            throw ValidationFailure("recovery did not recheck service health")
        }
        guard await probe.snapshot().attempts == 2 else {
            throw ValidationFailure("concurrent recovery calls did not coalesce")
        }
    }

    private static func processOutputAndTimeoutAreBounded() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "while :; do printf out; printf err >&2; done"],
            timeout: .milliseconds(100),
            outputLimit: 1_024
        )
        let elapsed = started.duration(to: clock.now)
        guard result.termination == .timedOut else {
            throw ValidationFailure("runaway process did not time out")
        }
        guard result.standardOutput.count <= 1_024, result.standardError.count <= 1_024 else {
            throw ValidationFailure("process output exceeded its configured bound")
        }
        guard elapsed < .seconds(2) else {
            throw ValidationFailure("process timeout cleanup exceeded its bound")
        }
    }

    private static func processCancellationIsBounded() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task {
            try await BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                timeout: .seconds(5),
                outputLimit: 1_024
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            throw ValidationFailure("cancelled process completed successfully")
        } catch is CancellationError {
            // Expected.
        }
        guard started.duration(to: clock.now) < .seconds(2) else {
            throw ValidationFailure("process cancellation cleanup exceeded its bound")
        }
    }

    private static func processIgnoringTermIsKilledWithinBound() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            timeout: .milliseconds(100),
            outputLimit: 1_024
        )
        guard result.termination == .timedOut else {
            throw ValidationFailure("TERM-resistant process did not time out")
        }
        guard started.duration(to: clock.now) < .seconds(2) else {
            throw ValidationFailure("TERM-to-KILL cleanup exceeded its bound")
        }
    }
}

private actor AppBootstrapProbe {
    private var results: [ServiceStartResult]
    private let resultDelay: Duration
    private var attempts = 0
    private var delays: [Duration] = []

    init(results: [ServiceStartResult], resultDelay: Duration = .zero) {
        self.results = results
        self.resultDelay = resultDelay
    }

    func nextResult() async -> ServiceStartResult {
        attempts += 1
        if resultDelay > .zero {
            try? await Task.sleep(for: resultDelay)
        }
        if results.count > 1 {
            return results.removeFirst()
        }
        return results.first ?? .failed(reason: "no result")
    }

    func recordSleep(_ duration: Duration) {
        delays.append(duration)
    }

    func snapshot() -> (attempts: Int, delays: [Duration]) {
        (attempts, delays)
    }
}

private actor ServiceStartupProbe {
    private var healthResponses: [Bool]
    private let launchDelay: Duration
    private var launchctlRuns = 0
    private var directRuns = 0

    init(healthResponses: [Bool], launchDelay: Duration = .zero) {
        self.healthResponses = healthResponses
        self.launchDelay = launchDelay
    }

    func healthCheck() -> Bool {
        guard healthResponses.count > 1 else {
            return healthResponses.first ?? false
        }
        return healthResponses.removeFirst()
    }

    func runLaunchctl() async throws {
        launchctlRuns += 1
        if launchDelay > .zero {
            try await Task.sleep(for: launchDelay)
        }
    }

    func runDirect() async throws {
        directRuns += 1
    }

    func counts() -> (launchctl: Int, direct: Int) {
        (launchctlRuns, directRuns)
    }
}

private final class UnixSocketValidationServer: @unchecked Sendable {
    let socketPath: String

    private let listener: Int32
    private let directory: URL
    private let queue = DispatchQueue(label: "dev.agentpet.transport-validation.server")

    init(handler: @escaping @Sendable (Int32) -> Void) throws {
        directory = URL(
            fileURLWithPath: "/tmp/apc-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("petcore.sock").path

        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw ValidationFailure("socket failed with errno \(errno)")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else {
            Darwin.close(listener)
            throw ValidationFailure("temporary socket path is too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                socketPath.withCString { source in
                    _ = strncpy(destination, source, capacity - 1)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(listener, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(listener, 1) == 0 else {
            let code = errno
            Darwin.close(listener)
            throw ValidationFailure("bind/listen failed with errno \(code)")
        }

        let acceptedListener = listener
        queue.async {
            let client = Darwin.accept(acceptedListener, nil, nil)
            guard client >= 0 else { return }
            handler(client)
            Darwin.close(client)
        }
    }

    deinit {
        Darwin.close(listener)
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct ValidationFailure: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

@discardableResult
private func readRequestLine(from descriptor: Int32) -> Data {
    var result = Data()
    var byte: UInt8 = 0
    while Darwin.read(descriptor, &byte, 1) == 1 {
        result.append(byte)
        if byte == 0x0A { break }
    }
    return result
}

private func waitForPeerToClose(_ descriptor: Int32) {
    var byte: UInt8 = 0
    while true {
        let count = Darwin.read(descriptor, &byte, 1)
        if count == 0 { return }
        if count < 0, errno != EINTR { return }
    }
}

private func writeAll(_ data: Data, to descriptor: Int32) {
    data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
            guard count > 0 else { return }
            offset += count
        }
    }
}

private func waitForSemaphore(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 1) == .success)
        }
    }
}
