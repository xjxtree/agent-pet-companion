import Darwin
import Foundation

public enum PetCoreTransportError: Error, Equatable, LocalizedError, Sendable {
    case socketPathTooLong
    case invalidParameters
    case requestTooLarge
    case responseTooLarge
    case timedOut
    case cancelled
    case peerClosed
    case systemCall(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .socketPathTooLong:
            "PetCore socket path is too long."
        case .invalidParameters:
            "PetCore request parameters are not valid JSON."
        case .requestTooLarge:
            "PetCore request exceeds the local transport limit."
        case .responseTooLarge:
            "PetCore response exceeds the local transport limit."
        case .timedOut:
            "PetCore request timed out."
        case .cancelled:
            "PetCore request was cancelled."
        case .peerClosed:
            "PetCore closed the connection before returning a complete response."
        case let .systemCall(operation, code):
            "PetCore \(operation) failed: \(String(cString: strerror(code)))."
        }
    }
}

public actor PetCoreTransport {
    public static let maximumFrameBytes = 256 * 1_024

    private let socketPath: String
    private let ioQueue: DispatchQueue
    private var nextRequestID: UInt64 = 0

    public init(socketPath: String) {
        self.socketPath = socketPath
        ioQueue = DispatchQueue(
            label: "dev.agentpet.petcore-transport",
            qos: .userInitiated,
            attributes: .concurrent
        )
    }

    public func request(
        method: String,
        params: Data? = nil,
        timeout: Duration = .seconds(5)
    ) async throws -> Data {
        try Task.checkCancellation()
        let paramsObject: Any
        if let params {
            guard let object = try? JSONSerialization.jsonObject(with: params) else {
                throw PetCoreTransportError.invalidParameters
            }
            paramsObject = object
        } else {
            paramsObject = [String: String]()
        }

        nextRequestID &+= 1
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "swift-\(nextRequestID)",
            "method": method,
            "params": paramsObject
        ]
        var frame = try JSONSerialization.data(withJSONObject: payload)
        frame.append(0x0A)
        guard frame.count <= Self.maximumFrameBytes + 1 else {
            throw PetCoreTransportError.requestTooLarge
        }

        let seconds = timeout.timeInterval
        guard seconds > 0 else {
            throw PetCoreTransportError.timedOut
        }
        let operation = try SocketRequestOperation(
            socketPath: socketPath,
            request: frame,
            timeout: seconds,
            maximumFrameBytes: Self.maximumFrameBytes
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ioQueue.async {
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

private final class SocketRequestOperation: @unchecked Sendable {
    private let socketPath: String
    private let request: Data
    private let maximumFrameBytes: Int
    private let deadline: UInt64
    private let cancellationRead: Int32
    private let cancellationWrite: Int32
    private let stateLock = NSLock()
    private var cancelled = false
    private var finished = false

    init(socketPath: String, request: Data, timeout: TimeInterval, maximumFrameBytes: Int) throws {
        self.socketPath = socketPath
        self.request = request
        self.maximumFrameBytes = maximumFrameBytes
        let timeoutNanoseconds = UInt64(min(timeout * 1_000_000_000, Double(UInt64.max)))
        deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds

        var descriptors = [Int32](repeating: -1, count: 2)
        let pipeResult = descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.pipe(buffer.baseAddress!)
        }
        guard pipeResult == 0 else {
            throw PetCoreTransportError.systemCall(operation: "cancellation pipe", code: errno)
        }
        cancellationRead = descriptors[0]
        cancellationWrite = descriptors[1]
        setNonBlocking(cancellationRead)
        setNonBlocking(cancellationWrite)
    }

    func cancel() {
        stateLock.lock()
        guard !cancelled, !finished else {
            stateLock.unlock()
            return
        }
        cancelled = true
        stateLock.unlock()

        var byte: UInt8 = 1
        _ = Darwin.write(cancellationWrite, &byte, 1)
    }

    func run() throws -> Data {
        defer {
            stateLock.lock()
            finished = true
            stateLock.unlock()
            Darwin.close(cancellationRead)
            Darwin.close(cancellationWrite)
        }
        try throwIfCancelled()

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw PetCoreTransportError.systemCall(operation: "socket", code: errno)
        }
        defer { Darwin.close(descriptor) }
        setNonBlocking(descriptor)
        var suppressPipeSignal: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &suppressPipeSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )

        try connect(descriptor)
        try writeRequest(descriptor)
        return try readResponse(descriptor)
    }

    private func connect(_ descriptor: Int32) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else {
            throw PetCoreTransportError.socketPathTooLong
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                socketPath.withCString { source in
                    _ = strncpy(destination, source, capacity - 1)
                }
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return }
        guard errno == EINPROGRESS else {
            throw PetCoreTransportError.systemCall(operation: "connect", code: errno)
        }

        _ = try waitForSocket(descriptor, events: Int16(POLLOUT))
        var socketError: Int32 = 0
        var errorLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) == 0 else {
            throw PetCoreTransportError.systemCall(operation: "connect", code: errno)
        }
        guard socketError == 0 else {
            throw PetCoreTransportError.systemCall(operation: "connect", code: socketError)
        }
    }

    private func writeRequest(_ descriptor: Int32) throws {
        try request.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                _ = try waitForSocket(descriptor, events: Int16(POLLOUT))
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                throw PetCoreTransportError.systemCall(operation: "write", code: errno)
            }
        }
    }

    private func readResponse(_ descriptor: Int32) throws -> Data {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            _ = try waitForSocket(descriptor, events: Int16(POLLIN))
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                response.append(buffer, count: count)
                if let newline = response.firstIndex(of: 0x0A) {
                    guard newline <= maximumFrameBytes else {
                        throw PetCoreTransportError.responseTooLarge
                    }
                    return Data(response[..<newline])
                }
                guard response.count <= maximumFrameBytes else {
                    throw PetCoreTransportError.responseTooLarge
                }
                continue
            }
            if count == 0 {
                throw PetCoreTransportError.peerClosed
            }
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }
            try throwIfCancelled()
            throw PetCoreTransportError.systemCall(operation: "read", code: errno)
        }
    }

    private func waitForSocket(_ descriptor: Int32, events: Int16) throws -> Int16 {
        while true {
            try throwIfCancelled()
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                throw PetCoreTransportError.timedOut
            }
            let nanosecondsRemaining = deadline - now
            let milliseconds = min(
                (nanosecondsRemaining + 999_999) / 1_000_000,
                UInt64(Int32.max)
            )
            var pollDescriptors = [
                pollfd(fd: descriptor, events: events, revents: 0),
                pollfd(fd: cancellationRead, events: Int16(POLLIN), revents: 0)
            ]
            let result = pollDescriptors.withUnsafeMutableBufferPointer { buffer in
                Darwin.poll(buffer.baseAddress, nfds_t(buffer.count), Int32(milliseconds))
            }
            if result == 0 {
                throw PetCoreTransportError.timedOut
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw PetCoreTransportError.systemCall(operation: "poll", code: errno)
            }
            if pollDescriptors[1].revents != 0 {
                throw PetCoreTransportError.cancelled
            }
            let revents = pollDescriptors[0].revents
            if revents & Int16(POLLNVAL) != 0 {
                throw PetCoreTransportError.systemCall(operation: "poll", code: EBADF)
            }
            if revents != 0 {
                return revents
            }
        }
    }

    private func throwIfCancelled() throws {
        stateLock.lock()
        let isCancelled = cancelled
        stateLock.unlock()
        if isCancelled {
            throw PetCoreTransportError.cancelled
        }
    }
}

private func setNonBlocking(_ descriptor: Int32) {
    let flags = fcntl(descriptor, F_GETFL)
    if flags >= 0 {
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
