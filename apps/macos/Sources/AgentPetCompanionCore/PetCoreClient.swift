import Foundation

public enum PetCoreClientError: Error, LocalizedError, Sendable {
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
    public let socketPath: String
    private let transport: PetCoreTransport

    public init(socketPath: String = PetCoreClient.defaultSocketPath()) {
        self.socketPath = socketPath
        transport = PetCoreTransport(socketPath: socketPath)
    }

    public static func defaultSocketPath() -> String {
        if let override = ProcessInfo.processInfo.environment["APC_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("run", isDirectory: true)
                .appendingPathComponent("petcore.sock")
                .path
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("AgentPetCompanion", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("petcore.sock")
            .path
    }

    /// Decodes a JSON-RPC result synchronously after the Sendable response
    /// bytes have crossed the async transport boundary. Keeping `Any` out of
    /// the async return type is required by Swift 6 actor isolation.
    public static func decodeResult(from response: Data) throws -> Any {
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

    public func requestData(
        method: String,
        paramsJSONData: Data? = nil,
        timeout: Duration? = nil
    ) async throws -> Data {
        try await transport.request(
            method: method,
            params: paramsJSONData,
            timeout: timeout ?? Self.defaultTimeout(for: method)
        )
    }

    public static func defaultTimeout(for method: String) -> Duration {
        switch method {
        case "pet.history", "petpack.import", "petpack.seed_bundled", "petpack.export", "diagnostics.export":
            .seconds(120)
        case "connections.check", "connections.repair", "connections.uninstall":
            .seconds(180)
        default:
            .seconds(5)
        }
    }
}
