import Darwin
import Foundation
import Testing
@testable import AgentPetCompanionCore

@Suite
struct PetCoreTransportTests {
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
    @Test
    func partialResponseDoesNotBlockMainActor() async throws {
        let partialWritten = DispatchSemaphore(value: 0)
        let server = try UnixSocketTestServer { client in
            _ = readRequestLine(from: client)
            writeAll(Data("{\"jsonrpc\":\"2.0\",\"result\":\"".utf8), to: client)
            partialWritten.signal()
            usleep(150_000)
            writeAll(Data("healthy\"}\n".utf8), to: client)
        }
        let transport = PetCoreTransport(socketPath: server.socketPath)
        let request = Task { @MainActor in
            try await transport.request(
                method: "petcore.health",
                params: Data("{}".utf8),
                timeout: .seconds(1)
            )
        }

        let didWritePartialResponse = await waitForSemaphore(partialWritten)
        #expect(didWritePartialResponse)
        let mainActorHeartbeat = Task { @MainActor in true }
        let heartbeat = await mainActorHeartbeat.value
        #expect(heartbeat)
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
        let clock = ContinuousClock()
        let started = clock.now
        let process = Task {
            try await BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                timeout: .seconds(5),
                outputLimit: 1_024
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        process.cancel()

        do {
            _ = try await process.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        #expect(started.duration(to: clock.now) < .seconds(2))
    }

    @Test
    func processIgnoringTermIsKilledWithinCleanupBound() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            timeout: .milliseconds(100),
            outputLimit: 1_024
        )

        #expect(result.termination == .timedOut)
        #expect(started.duration(to: clock.now) < .seconds(2))
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
    private let queue = DispatchQueue(label: "dev.agentpet.xctest.uds")

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
