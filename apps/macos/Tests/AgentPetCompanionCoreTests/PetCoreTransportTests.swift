import Darwin
import Foundation
import Testing
@testable import AgentPetCompanionCore

@Suite
struct PetCoreTransportTests {
    @Test
    func methodSpecificTimeoutBudgetsCoverBoundedLongOperations() {
        #expect(PetCoreClient.defaultTimeout(for: "state.snapshot") == .seconds(5))
        #expect(PetCoreClient.defaultTimeout(for: "connections.check") == .seconds(180))
        #expect(PetCoreClient.defaultTimeout(for: "connections.repair") == .seconds(180))
        #expect(
            PetCoreClient.defaultTimeout(for: "connections.refresh_installed")
                == .seconds(180)
        )
        #expect(PetCoreClient.defaultTimeout(for: "connections.uninstall") == .seconds(180))
        #expect(PetCoreClient.defaultTimeout(for: "petpack.export") == .seconds(120))
        #expect(PetCoreClient.defaultTimeout(for: "pet.history") == .seconds(120))
    }

    @Test
    func clientResultDecodingValidatesEnvelopeWithoutCrossingAsyncAny() throws {
        let success = try PetCoreClient.decodeResult(
            from: Data(#"{"jsonrpc":"2.0","result":{"ok":true}}"#.utf8)
        )
        #expect((success as? [String: Any])?["ok"] as? Bool == true)

        let empty = try PetCoreClient.decodeResult(from: Data(#"{"jsonrpc":"2.0"}"#.utf8))
        #expect(empty is NSNull)

        do {
            _ = try PetCoreClient.decodeResult(
                from: Data(#"{"jsonrpc":"2.0","error":{"message":"boom"}}"#.utf8)
            )
            Issue.record("Expected an RPC error")
        } catch let PetCoreClientError.rpcError(message) {
            #expect(message == "boom")
        }

        do {
            _ = try PetCoreClient.decodeResult(from: Data("[]".utf8))
            Issue.record("Expected an invalid response")
        } catch PetCoreClientError.invalidResponse {
            // Expected.
        }
    }

    @Test
    func requestTimesOut() async throws {
        let server = try UnixSocketTestServer { client in
            _ = readRequestLine(from: client)
            waitForPeerToClose(client)
        }
        defer { withExtendedLifetime(server) {} }
        let transport = PetCoreTransport(socketPath: server.socketPath)

        do {
            _ = try await transport.request(
                method: "petcore.health",
                params: Data("{}".utf8),
                timeout: .milliseconds(100)
            )
            Issue.record("Expected timeout")
        } catch PetCoreTransportError.timedOut {
            // Expected.
        }
    }

    @Test
    func taskCancellationClosesConnection() async throws {
        let received = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)
        let server = try UnixSocketTestServer { client in
            _ = readRequestLine(from: client)
            received.signal()
            waitForPeerToClose(client)
            closed.signal()
        }
        defer { withExtendedLifetime(server) {} }
        let transport = PetCoreTransport(socketPath: server.socketPath)
        let request = Task {
            try await transport.request(
                method: "state.wait",
                params: Data("{}".utf8),
                timeout: .seconds(5)
            )
        }

        let didReceive = await waitForSemaphore(received)
        #expect(didReceive)
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch PetCoreTransportError.cancelled {
            // Accepted transport normalization.
        }
        let didClose = await waitForSemaphore(closed)
        #expect(didClose)
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func partialResponseDoesNotBlockMainActor() async throws {
        let partialWritten = DispatchSemaphore(value: 0)
        let allowCompletion = DispatchSemaphore(value: 0)
        let fullResponseWritten = DispatchSemaphore(value: 0)
        let requestStarted = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let server = try UnixSocketTestServer { client in
            _ = readRequestLine(from: client)
            writeAll(Data("{\"jsonrpc\":\"2.0\",\"result\":\"".utf8), to: client)
            partialWritten.signal()
            guard allowCompletion.wait(timeout: .now() + .seconds(30)) == .success else {
                return
            }
            writeAll(Data("healthy\"}\n".utf8), to: client)
            fullResponseWritten.signal()
        }
        defer {
            allowCompletion.signal()
            withExtendedLifetime(server) {}
        }
        let transport = PetCoreTransport(socketPath: server.socketPath)
        let request = Task { @MainActor in
            requestStarted.continuation.yield(())
            requestStarted.continuation.finish()
            return try await transport.request(
                method: "petcore.health",
                params: Data("{}".utf8),
                // This test controls completion itself. Keep transport timeout
                // beyond the 30-second fixture escape hatch so renderer load
                // cannot turn MainActor scheduling into a timeout assertion.
                timeout: .seconds(45)
            )
        }

        // Swift Testing may have many MainActor visual tests ready at once. Do
        // not start the server observation timeout until this request task has
        // actually received a MainActor turn; otherwise scheduler contention
        // is mistaken for a transport failure.
        var requestStartedIterator = requestStarted.stream.makeAsyncIterator()
        let didStartRequest = await requestStartedIterator.next() != nil
        #expect(didStartRequest)
        let didWritePartialResponse = await waitForSemaphore(partialWritten)
        #expect(didWritePartialResponse)
        let mainActorHeartbeat = Task { @MainActor in true }
        let heartbeat = await mainActorHeartbeat.value
        #expect(heartbeat)
        let completedBeforePermission = await waitForSemaphore(
            fullResponseWritten,
            timeout: .nanoseconds(0)
        )
        #expect(!completedBeforePermission)
        allowCompletion.signal()
        let didWriteFullResponse = await waitForSemaphore(fullResponseWritten)
        #expect(didWriteFullResponse)
        let response = try await request.value
        #expect(String(decoding: response, as: UTF8.self).contains("healthy"))
    }

    @Test
    func appBootstrapRetriesWithBoundedExponentialBackoff() async {
        let probe = BootstrapProbe(results: [
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

        let result = await coordinator.ensureRunning()
        #expect(result == .started)
        let snapshot = await probe.snapshot()
        #expect(snapshot.attempts == 3)
        #expect(snapshot.delays == [.milliseconds(10), .milliseconds(20)])
    }

    @Test
    func appBootstrapResetsAfterTerminalFailure() async {
        let probe = BootstrapProbe(results: [
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
            Issue.record("Expected terminal failure")
            return
        }
        let retryResult = await coordinator.ensureRunning()
        #expect(retryResult == .started)
        let snapshot = await probe.snapshot()
        #expect(snapshot.attempts == 3)
    }

    @Test
    func appBootstrapDefersWithoutRetryingOrCachingActiveWork() async {
        let probe = BootstrapProbe(results: [
            .deferred(reason: "active generation"),
            .started
        ])
        let coordinator = PetCoreAppBootstrapCoordinator(
            ensureRunning: { await probe.nextResult() },
            policy: ServiceBootstrapRetryPolicy(
                maximumAttempts: 5,
                initialDelay: .milliseconds(10),
                maximumDelay: .milliseconds(20)
            ),
            sleep: { duration in await probe.recordSleep(duration) }
        )

        #expect(
            await coordinator.ensureRunning()
                == .deferred(reason: "active generation")
        )
        var snapshot = await probe.snapshot()
        #expect(snapshot.attempts == 1)
        #expect(snapshot.delays.isEmpty)

        #expect(await coordinator.ensureRunning() == .started)
        snapshot = await probe.snapshot()
        #expect(snapshot.attempts == 2)
    }

    @Test
    func processOutputAndTimeoutAreBounded() async throws {
        let result = try await BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "while :; do printf out; printf err >&2; done"],
            timeout: .milliseconds(100),
            outputLimit: 1_024
        )

        #expect(result.termination == .timedOut)
        #expect(result.standardOutput.count <= 1_024)
        #expect(result.standardError.count <= 1_024)
    }

    @Test
    func processCancellationIsBounded() async throws {
        let processIdentifierFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-process-cancel-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: processIdentifierFile) }

        let process = Task {
            try await BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    """
                    trap '' TERM
                    /bin/sh -c 'trap "" TERM; while :; do sleep 1; done' &
                    child=$!
                    printf '%s %s\n' "$$" "$child" > "$1"
                    while :; do sleep 1; done
                    """,
                    "bounded-process-cancel",
                    processIdentifierFile.path
                ],
                timeout: .seconds(5),
                outputLimit: 1_024
            )
        }
        let processIdentifiers = await waitForProcessIdentifiers(
            at: processIdentifierFile,
            expectedCount: 2,
            // Starting the utility-QoS operation can be delayed while Swift
            // Testing runs hundreds of cases concurrently on CI. Startup is
            // not part of the cancellation bound exercised below.
            timeout: .seconds(5)
        )
        guard processIdentifiers.count == 2 else {
            process.cancel()
            _ = try? await process.value
            Issue.record("Expected the process group fixture to start")
            return
        }

        let clock = ContinuousClock()
        let cancellationStarted = clock.now
        process.cancel()

        do {
            _ = try await process.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        #expect(cancellationStarted.duration(to: clock.now) < .seconds(2))
        #expect(await waitForProcessesToExit(processIdentifiers))
        #expect(processIdentifiers.first.map(processGroupHasExited) == true)
    }

    @Test
    func processIgnoringTermIsKilledWithinCleanupBound() async throws {
        let processIdentifierFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-process-timeout-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: processIdentifierFile) }

        let process = Task {
            try await BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    """
                    trap '' TERM
                    printf '%s\n' "$$" > "$1"
                    while :; do :; done
                    """,
                    "bounded-process-timeout",
                    processIdentifierFile.path
                ],
                timeout: .milliseconds(500),
                outputLimit: 1_024
            )
        }
        let processIdentifiers = await waitForProcessIdentifiers(
            at: processIdentifierFile,
            expectedCount: 1,
            // Swift Testing may delay the utility-QoS operation while the
            // complete suite runs concurrently. Startup is not cleanup time.
            timeout: .seconds(5)
        )
        guard processIdentifiers.count == 1 else {
            process.cancel()
            _ = try? await process.value
            Issue.record("Expected the timeout fixture to start")
            return
        }

        let clock = ContinuousClock()
        let started = clock.now
        let result = try await process.value

        #expect(result.termination == .timedOut)
        #expect(started.duration(to: clock.now) < .seconds(2))
        #expect(await waitForProcessesToExit(processIdentifiers))
        #expect(processIdentifiers.first.map(processGroupHasExited) == true)
    }

    @Test
    func processTimeoutKillsIgnoringTermDescendants() async throws {
        let result = try await BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                """
                trap '' TERM
                /bin/sh -c 'trap "" TERM; while :; do sleep 1; done' &
                child=$!
                printf '%s %s\n' "$$" "$child"
                while :; do sleep 1; done
                """
            ],
            timeout: .milliseconds(150),
            outputLimit: 1_024
        )

        #expect(result.termination == .timedOut)
        let processIdentifiers = parseProcessIdentifiers(result.standardOutput)
        #expect(processIdentifiers.count == 2)
        #expect(await waitForProcessesToExit(processIdentifiers))
        #expect(processIdentifiers.first.map(processGroupHasExited) == true)
    }

    @Test
    func processNormalExitCleansRedirectedDescendantsAndPreservesResult() async throws {
        let processIdentifierFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-process-normal-exit-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: processIdentifierFile) }

        let unrelatedProcess = Process()
        unrelatedProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelatedProcess.arguments = ["30"]
        try unrelatedProcess.run()
        defer {
            if unrelatedProcess.isRunning {
                unrelatedProcess.terminate()
                unrelatedProcess.waitUntilExit()
            }
        }

        let result = try await BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                """
                /bin/sh -c 'trap "" TERM; while :; do sleep 1; done' \
                    </dev/null >/dev/null 2>&1 &
                child=$!
                printf '%s %s\n' "$$" "$child" > "$1"
                printf 'leader-output\n'
                printf 'leader-error\n' >&2
                exit 7
                """,
                "bounded-process-normal-exit",
                processIdentifierFile.path
            ],
            timeout: .seconds(2),
            outputLimit: 1_024
        )

        let processIdentifiers = await waitForProcessIdentifiers(
            at: processIdentifierFile,
            expectedCount: 2
        )
        #expect(result.termination == .exited(status: 7))
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "leader-output\n")
        #expect(String(decoding: result.standardError, as: UTF8.self) == "leader-error\n")
        #expect(processIdentifiers.count == 2)
        #expect(await waitForProcessesToExit(processIdentifiers))
        #expect(processIdentifiers.first.map(processGroupHasExited) == true)
        #expect(unrelatedProcess.isRunning)
    }

    @Test
    func processGroupCleanupDoesNotSignalUnrelatedProcess() async throws {
        let unrelatedProcess = Process()
        unrelatedProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelatedProcess.arguments = ["5"]
        try unrelatedProcess.run()
        defer {
            if unrelatedProcess.isRunning {
                unrelatedProcess.terminate()
                unrelatedProcess.waitUntilExit()
            }
        }

        let result = try await BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            timeout: .milliseconds(100),
            outputLimit: 1_024
        )

        #expect(result.termination == .timedOut)
        #expect(unrelatedProcess.isRunning)
    }
}

private actor BootstrapProbe {
    private var results: [ServiceStartResult]
    private var attempts = 0
    private var delays: [Duration] = []

    init(results: [ServiceStartResult]) {
        self.results = results
    }

    func nextResult() -> ServiceStartResult {
        attempts += 1
        if results.count > 1 { return results.removeFirst() }
        return results.first ?? .failed(reason: "no result")
    }

    func recordSleep(_ duration: Duration) {
        delays.append(duration)
    }

    func snapshot() -> (attempts: Int, delays: [Duration]) {
        (attempts, delays)
    }
}

private final class UnixSocketTestServer: @unchecked Sendable {
    let socketPath: String

    private let listener: Int32
    private let directory: URL
    // Keep the local peer runnable while Swift Testing is saturating its
    // parallel worker pool with renderer and process fixtures. A default-QoS
    // accept queue can otherwise be starved long enough for the observation
    // below to time out before the server has written its first bytes.
    private let queue = DispatchQueue(
        label: "dev.agentpet.xctest.uds",
        qos: .userInitiated
    )

    init(handler: @escaping @Sendable (Int32) -> Void) throws {
        directory = URL(fileURLWithPath: "/tmp/apc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("petcore.sock").path
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXTestError(code: errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else {
            Darwin.close(listener)
            throw POSIXTestError(code: ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                socketPath.withCString { source in _ = strncpy(destination, source, capacity - 1) }
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(listener, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, 1) == 0 else {
            let code = errno
            Darwin.close(listener)
            throw POSIXTestError(code: code)
        }

        let acceptedListener = listener
        queue.async {
            let client = Darwin.accept(acceptedListener, nil, nil)
            guard client >= 0 else { return }
            var suppressPipeSignal: Int32 = 1
            _ = setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &suppressPipeSignal,
                socklen_t(MemoryLayout<Int32>.size)
            )
            handler(client)
            Darwin.close(client)
        }
    }

    deinit {
        Darwin.close(listener)
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct POSIXTestError: Error { let code: Int32 }

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
    while Darwin.read(descriptor, &byte, 1) > 0 {}
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

private func waitForSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTimeInterval = .seconds(3)
) async -> Bool {
    await withCheckedContinuation { continuation in
        // A dedicated user-initiated queue prevents the test runner's highly
        // parallel global pool from starving this bounded observation task.
        // The wait remains off the MainActor, which is the behavior under test.
        DispatchQueue(
            label: "dev.agentpet.tests.semaphore-wait",
            qos: .userInitiated
        ).async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + timeout) == .success)
        }
    }
}

private func parseProcessIdentifiers(_ data: Data) -> [pid_t] {
    String(decoding: data, as: UTF8.self)
        .split(whereSeparator: { $0.isWhitespace })
        .compactMap { pid_t(String($0)) }
        .filter { $0 > 1 }
}

private func waitForProcessIdentifiers(
    at url: URL,
    expectedCount: Int,
    timeout: Duration = .seconds(1)
) async -> [pid_t] {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if let data = try? Data(contentsOf: url) {
            let identifiers = parseProcessIdentifiers(data)
            if identifiers.count >= expectedCount {
                return identifiers
            }
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return []
}

private func waitForProcessesToExit(
    _ processIdentifiers: [pid_t],
    timeout: Duration = .seconds(1)
) async -> Bool {
    guard !processIdentifiers.isEmpty else { return false }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    repeat {
        if processIdentifiers.allSatisfy(processHasExited) {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    } while clock.now < deadline
    return processIdentifiers.allSatisfy(processHasExited)
}

private func processHasExited(_ processIdentifier: pid_t) -> Bool {
    Darwin.kill(processIdentifier, 0) == -1 && errno == ESRCH
}

private func processGroupHasExited(_ processGroupIdentifier: pid_t) -> Bool {
    Darwin.kill(-processGroupIdentifier, 0) == -1 && errno == ESRCH
}
