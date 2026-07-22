import AgentPetCompanionCore
import Foundation

enum AgentConnectionOperationKind: String, Equatable, Sendable {
    case check
    case test
    case repair
    case uninstall
}

struct AgentConnectionOperation: Equatable, Sendable {
    let kind: AgentConnectionOperationKind
    let sources: [AgentSource]

    init(kind: AgentConnectionOperationKind, sources: [AgentSource]) {
        self.kind = kind
        self.sources = AgentSource.allCases.filter { sources.contains($0) }
    }
}

struct AgentConnectionOperationFailure: Equatable, Sendable {
    let operation: AgentConnectionOperation
    let reason: AgentConnectionOperationFailureReason
}

enum AgentConnectionOperationFailureReason: String, Equatable, Sendable {
    case transportUnavailable = "transport_unavailable"
    case rejected
    case partialFailure = "partial_failure"
    case invalidResponse = "invalid_response"
    case invalidRequest = "invalid_request"
    case unknown
}

enum AgentConnectionOperationState: Equatable, Sendable {
    case idle
    case running(AgentConnectionOperation)
    case succeeded(AgentConnectionOperation)
    case failed(AgentConnectionOperationFailure)

    var runningOperation: AgentConnectionOperation? {
        guard case let .running(operation) = self else { return nil }
        return operation
    }

    var failedOperation: AgentConnectionOperationFailure? {
        guard case let .failed(failure) = self else { return nil }
        return failure
    }

    var isRunning: Bool { runningOperation != nil }
}

struct AgentConnectionOperationPermit: Equatable, Sendable {
    fileprivate let id: UUID
    let operation: AgentConnectionOperation
}

struct AgentConnectionOperationGate: Sendable {
    private var activePermit: AgentConnectionOperationPermit?

    var activeOperation: AgentConnectionOperation? {
        activePermit?.operation
    }

    mutating func begin(
        _ operation: AgentConnectionOperation
    ) -> AgentConnectionOperationPermit? {
        guard activePermit == nil, !operation.sources.isEmpty else { return nil }
        let permit = AgentConnectionOperationPermit(id: UUID(), operation: operation)
        activePermit = permit
        return permit
    }

    mutating func finish(_ permit: AgentConnectionOperationPermit) {
        guard activePermit?.id == permit.id else { return }
        activePermit = nil
    }
}

struct AgentConnectionOperationExecutionError: LocalizedError, Equatable, Sendable {
    let reason: AgentConnectionOperationFailureReason

    init(_ reason: AgentConnectionOperationFailureReason) {
        self.reason = reason
    }

    var errorDescription: String? { reason.rawValue }
}
