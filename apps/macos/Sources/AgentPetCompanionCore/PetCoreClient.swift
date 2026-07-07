import Darwin
import Foundation

public enum PetCoreClientError: Error, LocalizedError {
    case socketPathTooLong
    case connectFailed(String)
    case writeFailed
    case invalidResponse
    case rpcError(String)

    public var errorDescription: String? {
        switch self {
        case .socketPathTooLong: "PetCore socket path is too long."
        case let .connectFailed(message): "Could not connect to PetCore: \(message)"
        case .writeFailed: "Could not write request to PetCore."
        case .invalidResponse: "PetCore returned an invalid response."
        case let .rpcError(message): message
        }
    }
}

public struct PetCoreClient: Sendable {
    public var socketPath: String

    public init(socketPath: String = PetCoreClient.defaultSocketPath()) {
        self.socketPath = socketPath
    }

    public static func defaultSocketPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("AgentPetCompanion", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("petcore.sock")
            .path
    }

    public func request(method: String, params: Any = [:]) throws -> Any {
        let paramsData = try JSONSerialization.data(withJSONObject: params)
        let response = try requestData(method: method, paramsJSONData: paramsData)
        guard
            let object = try JSONSerialization.jsonObject(with: response) as? [String: Any]
        else {
            throw PetCoreClientError.invalidResponse
        }
        if let error = object["error"] as? [String: Any] {
            throw PetCoreClientError.rpcError(String(describing: error["message"] ?? "Unknown PetCore error"))
        }
        return object["result"] ?? NSNull()
    }

    public func requestData(method: String, paramsJSONData: Data? = nil) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw PetCoreClientError.connectFailed(String(cString: strerror(errno)))
        }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: address.sun_path)
        if socketPath.utf8.count >= maxPath {
            throw PetCoreClientError.socketPathTooLong
        }

        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPath) { rawPointer in
                socketPath.withCString { source in
                    strncpy(rawPointer, source, maxPath - 1)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult != 0 {
            throw PetCoreClientError.connectFailed(String(cString: strerror(errno)))
        }

        let params: Any
        if let paramsJSONData {
            params = try JSONSerialization.jsonObject(with: paramsJSONData)
        } else {
            params = [:]
        }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "swift",
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        var bytes = [UInt8](data)
        bytes.append(10)
        try bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    fd,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if result <= 0 {
                    throw PetCoreClientError.writeFailed
                }
                written += result
            }
        }
        shutdown(fd, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            response.append(buffer, count: count)
        }

        return response
    }
}
