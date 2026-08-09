import Foundation

public enum GenerationSessionState: String, CaseIterable, Codable, Hashable, Sendable {
    case idle
    case starting
    case running
    case waitingForInput
    case paused
    case recoverableFailed
    case cancelling
    case cancelCleanup
    case succeeded
    case failed
    case cancelled

    public var isActive: Bool {
        switch self {
        case .starting, .running, .waitingForInput, .paused, .recoverableFailed,
             .cancelling, .cancelCleanup:
            true
        case .idle, .succeeded, .failed, .cancelled:
            false
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled:
            true
        case .idle, .starting, .running, .waitingForInput, .paused, .recoverableFailed,
             .cancelling, .cancelCleanup:
            false
        }
    }
}

public struct GenerationSessionEffects: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let startMessageStream = Self(rawValue: 1 << 0)
    public static let stopMessageStream = Self(rawValue: 1 << 1)
    public static let refreshSnapshot = Self(rawValue: 1 << 2)
}

public struct GenerationSessionRestore: Equatable, Sendable {
    public var state: GenerationSessionState
    public var jobID: String
    public var submittedForm: GenerationForm?
    public var messages: [GenerationMessage]
    public var progress: Double
    public var messageRevision: String
    public var heartbeatAt: String?
    public var startedAt: String?
    public var endedAt: String?
    public var recoverable: Bool
    public var failureCode: String?
    public var pauseReason: String?
    public var cancellationPending: Bool
    public var capabilities: GenerationSessionCapabilities?
    public var operation: GenerationOperation
    public var resultPetID: String?
    public var baselineRevisionID: String?
    public var resultRevisionID: String?
    public var validationSummary: GenerationValidationSummary?
    public var referenceReselectionCount: Int

    public init(
        state: GenerationSessionState,
        jobID: String,
        submittedForm: GenerationForm?,
        messages: [GenerationMessage],
        progress: Double,
        messageRevision: String,
        heartbeatAt: String? = nil,
        startedAt: String? = nil,
        endedAt: String? = nil,
        recoverable: Bool = false,
        failureCode: String? = nil,
        pauseReason: String? = nil,
        cancellationPending: Bool = false,
        capabilities: GenerationSessionCapabilities? = nil,
        operation: GenerationOperation = .create,
        resultPetID: String? = nil,
        baselineRevisionID: String? = nil,
        resultRevisionID: String? = nil,
        validationSummary: GenerationValidationSummary? = nil,
        referenceReselectionCount: Int = 0
    ) {
        self.state = state
        self.jobID = jobID
        self.submittedForm = submittedForm
        self.messages = messages
        self.progress = progress
        self.messageRevision = messageRevision
        self.heartbeatAt = heartbeatAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.recoverable = recoverable
        self.failureCode = failureCode
        self.pauseReason = pauseReason
        self.cancellationPending = cancellationPending
        self.capabilities = capabilities
        self.operation = operation
        self.resultPetID = resultPetID
        self.baselineRevisionID = baselineRevisionID
        self.resultRevisionID = resultRevisionID
        self.validationSummary = validationSummary
        self.referenceReselectionCount = min(4, max(0, referenceReselectionCount))
    }

    public init(snapshot: ActiveGenerationSnapshot) {
        var messages = snapshot.messages
        if let inputRequest = snapshot.inputRequest,
           !messages.contains(where: { $0.id == inputRequest.id }) {
            messages.append(inputRequest)
        }
        if snapshot.cancellationPending {
            state = .cancelCleanup
        } else {
            state = switch snapshot.status {
            case .pending: .starting
            case .running: .running
            case .waitingForUser: .waitingForInput
            case .failed:
                if snapshot.recoverable {
                    snapshot.failureCode == "owner_interrupted" ? .paused : .recoverableFailed
                } else {
                    .failed
                }
            }
        }
        jobID = snapshot.jobID
        submittedForm = snapshot.form
        self.messages = messages
        progress = messages.last?.progress ?? snapshot.inputRequest?.progress ?? 0
        messageRevision = snapshot.messageRevision
        heartbeatAt = snapshot.heartbeatAt
        startedAt = snapshot.startedAt
        endedAt = snapshot.endedAt
        recoverable = snapshot.recoverable
        failureCode = snapshot.failureCode
        pauseReason = snapshot.pauseReason
        cancellationPending = snapshot.cancellationPending
        capabilities = snapshot.capabilities
        operation = snapshot.operation ?? .create
        resultPetID = snapshot.resultPetID
        baselineRevisionID = snapshot.baselineRevisionID
        resultRevisionID = nil
        validationSummary = nil
        referenceReselectionCount = min(4, max(0, snapshot.referenceReselectionCount))
    }

    public init?(snapshot: LatestGenerationSessionSnapshot) {
        guard snapshot.found,
              let jobID = snapshot.jobID,
              !jobID.isEmpty,
              let status = snapshot.status,
              snapshot.form != nil,
              (0 ... 4).contains(snapshot.referenceReselectionCount)
        else { return nil }
        if snapshot.cancellationPending {
            state = .cancelCleanup
        } else {
            state = switch status {
            case .pending: .starting
            case .running: .running
            case .waitingForUser: .waitingForInput
            case .completed: .succeeded
            case .failed:
                if snapshot.recoverable {
                    snapshot.failureCode == "owner_interrupted" ? .paused : .recoverableFailed
                } else {
                    .failed
                }
            case .canceled: .cancelled
            }
        }
        self.jobID = jobID
        submittedForm = snapshot.form
        messages = snapshot.messages
        progress = snapshot.messages.last?.progress ?? (state.isTerminal ? 1 : 0)
        messageRevision = snapshot.messageRevision
        heartbeatAt = snapshot.heartbeatAt
        startedAt = snapshot.startedAt
        endedAt = snapshot.endedAt
        recoverable = snapshot.recoverable
        failureCode = snapshot.failureCode
        pauseReason = snapshot.pauseReason
        cancellationPending = snapshot.cancellationPending
        capabilities = snapshot.capabilities
        operation = snapshot.operation ?? .create
        resultPetID = snapshot.resultPetID
        baselineRevisionID = snapshot.baselineRevisionID
        resultRevisionID = snapshot.revisionID
        validationSummary = snapshot.validationSummary
        referenceReselectionCount = snapshot.referenceReselectionCount
    }
}

public enum GenerationSessionAction: Equatable, Sendable {
    case startRequested(form: GenerationForm, initialMessage: GenerationMessage)
    case editRequested(
        form: GenerationForm,
        initialMessage: GenerationMessage,
        petID: String,
        baselineRevisionID: String? = nil
    )
    case retryRequested(form: GenerationForm, initialMessage: GenerationMessage)
    case resumeRequested
    case resumeFailed(restoring: GenerationSessionState)
    case startAccepted(
        jobID: String,
        baselineRevisionID: String? = nil
    )
    case startFailed(message: GenerationMessage)
    case messagesReceived([GenerationMessage], revision: String?)
    case heartbeatReceived(String?)
    case resultMetadataReceived(GenerationResultMetadata)
    case restore(GenerationSessionRestore)
    case replySubmitted
    case replyFailed(restoring: GenerationSessionState)
    case cancelRequested
    case cancelConfirmed
    case cancelFailed
    case resetMessageRevision
    case reset
}

public struct GenerationSession: Equatable, Sendable {
    public private(set) var state: GenerationSessionState
    public private(set) var jobID: String?
    public private(set) var submittedForm: GenerationForm?
    public private(set) var messages: [GenerationMessage]
    public private(set) var progress: Double
    public private(set) var messageRevision: String
    public private(set) var heartbeatAt: String?
    public private(set) var startedAt: String?
    public private(set) var endedAt: String?
    public private(set) var recoverable: Bool
    public private(set) var failureCode: String?
    public private(set) var pauseReason: String?
    public private(set) var cancellationPending: Bool
    public private(set) var capabilities: GenerationSessionCapabilities?
    public private(set) var operation: GenerationOperation
    public private(set) var resultPetID: String?
    public private(set) var baselineRevisionID: String?
    public private(set) var resultRevisionID: String?
    public private(set) var validationSummary: GenerationValidationSummary?
    public private(set) var referenceReselectionCount: Int

    public init(
        state: GenerationSessionState = .idle,
        jobID: String? = nil,
        submittedForm: GenerationForm? = nil,
        messages: [GenerationMessage] = [],
        progress: Double = 0,
        messageRevision: String = "",
        heartbeatAt: String? = nil,
        startedAt: String? = nil,
        endedAt: String? = nil,
        recoverable: Bool = false,
        failureCode: String? = nil,
        pauseReason: String? = nil,
        cancellationPending: Bool = false,
        capabilities: GenerationSessionCapabilities? = nil,
        operation: GenerationOperation = .create,
        resultPetID: String? = nil,
        baselineRevisionID: String? = nil,
        resultRevisionID: String? = nil,
        validationSummary: GenerationValidationSummary? = nil,
        referenceReselectionCount: Int = 0
    ) {
        self.state = state
        self.jobID = jobID
        self.submittedForm = submittedForm
        self.messages = messages
        self.progress = progress
        self.messageRevision = messageRevision
        self.heartbeatAt = heartbeatAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.recoverable = recoverable
        self.failureCode = failureCode
        self.pauseReason = pauseReason
        self.cancellationPending = cancellationPending
        self.capabilities = capabilities
        self.operation = operation
        self.resultPetID = resultPetID
        self.baselineRevisionID = baselineRevisionID
        self.resultRevisionID = resultRevisionID
        self.validationSummary = validationSummary
        self.referenceReselectionCount = min(4, max(0, referenceReselectionCount))
    }

    public var isActive: Bool { state.isActive }

    public var canCancel: Bool {
        guard jobID != nil else { return false }
        return capabilities?.canCancel
            ?? [.starting, .running, .waitingForInput, .paused, .recoverableFailed].contains(state)
    }

    public var canSendReply: Bool {
        jobID != nil && (capabilities?.canReply ?? (state == .waitingForInput))
    }

    public var canRetry: Bool {
        submittedForm != nil && state == .failed
    }

    public var canResume: Bool {
        submittedForm != nil
            && jobID != nil
            && (capabilities?.canResume ?? [.paused, .recoverableFailed].contains(state))
    }

    @discardableResult
    public mutating func reduce(_ action: GenerationSessionAction) -> GenerationSessionEffects {
        switch action {
        case let .startRequested(form, initialMessage):
            guard !state.isActive else { return [] }
            state = .starting
            jobID = nil
            submittedForm = form
            messages = [initialMessage]
            progress = initialMessage.progress
            messageRevision = ""
            heartbeatAt = nil
            startedAt = nil
            endedAt = nil
            recoverable = false
            failureCode = nil
            pauseReason = nil
            cancellationPending = false
            capabilities = nil
            operation = .create
            resultPetID = nil
            baselineRevisionID = nil
            resultRevisionID = nil
            validationSummary = nil
            referenceReselectionCount = 0
            return []

        case let .editRequested(form, initialMessage, petID, baselineRevisionID):
            guard !state.isActive, !petID.isEmpty else { return [] }
            state = .starting
            jobID = nil
            submittedForm = form
            messages = [initialMessage]
            progress = initialMessage.progress
            messageRevision = ""
            heartbeatAt = nil
            startedAt = nil
            endedAt = nil
            recoverable = false
            failureCode = nil
            pauseReason = nil
            cancellationPending = false
            capabilities = nil
            operation = .modify
            resultPetID = petID
            self.baselineRevisionID = baselineRevisionID
            resultRevisionID = nil
            validationSummary = nil
            referenceReselectionCount = 0
            return []

        case let .retryRequested(form, initialMessage):
            guard canRetry, jobID != nil else { return [] }
            state = .starting
            submittedForm = form
            messages = [initialMessage]
            progress = initialMessage.progress
            messageRevision = ""
            heartbeatAt = nil
            resultRevisionID = nil
            validationSummary = nil
            referenceReselectionCount = 0
            // Keep jobID, operation, resultPetID, and baselineRevisionID until
            // the retry RPC is accepted. If transport/startup fails, the same
            // safe immutable baseline can be retried instead of falling back
            // to the current head or a new create job.
            return []

        case .resumeRequested:
            guard canResume else { return [] }
            state = .starting
            return []

        case let .resumeFailed(previousState):
            guard state == .starting,
                  previousState == .paused || previousState == .recoverableFailed
            else { return [] }
            state = previousState
            return []

        case let .resultMetadataReceived(metadata):
            if let petID = metadata.resultPetID, !petID.isEmpty {
                if operation == .modify,
                   let currentPetID = resultPetID,
                   currentPetID != petID {
                    return []
                }
                resultPetID = petID
            }
            if let revisionID = metadata.revisionID, !revisionID.isEmpty {
                resultRevisionID = revisionID
            }
            if let summary = metadata.validationSummary {
                validationSummary = summary
            }
            return []

        case let .startAccepted(jobID, baselineRevisionID):
            guard state == .starting else { return [] }
            self.jobID = jobID
            if let baselineRevisionID {
                self.baselineRevisionID = baselineRevisionID
            }
            state = .running
            return [.startMessageStream]

        case let .startFailed(message):
            guard state == .starting else { return [] }
            messages.append(message)
            progress = message.progress
            state = .failed
            return [.stopMessageStream]

        case let .messagesReceived(messages, revision):
            if let revision {
                messageRevision = revision
            }
            guard !messages.isEmpty else { return [] }
            self.messages = messages
            progress = messages.last?.progress ?? progress
            guard !state.isTerminal else { return [] }

            let nextState = Self.state(for: messages)
            if state == .cancelling, !nextState.isTerminal {
                return []
            }
            state = nextState
            if nextState.isTerminal {
                return [.stopMessageStream, .refreshSnapshot]
            }
            return []

        case let .heartbeatReceived(heartbeatAt):
            self.heartbeatAt = heartbeatAt
            return []

        case let .restore(restore):
            let previousJobID = jobID
            let wasActive = state.isActive
            state = restore.state
            jobID = restore.jobID
            submittedForm = restore.submittedForm
            messages = restore.messages
            progress = restore.progress
            messageRevision = restore.messageRevision
            heartbeatAt = restore.heartbeatAt
            startedAt = restore.startedAt
            endedAt = restore.endedAt
            recoverable = restore.recoverable
            failureCode = restore.failureCode
            pauseReason = restore.pauseReason
            cancellationPending = restore.cancellationPending
            capabilities = restore.capabilities
            operation = restore.operation
            resultPetID = restore.resultPetID
            baselineRevisionID = restore.baselineRevisionID
            resultRevisionID = restore.resultRevisionID
            validationSummary = restore.validationSummary
            referenceReselectionCount = restore.referenceReselectionCount
            var effects: GenerationSessionEffects = []
            if wasActive, previousJobID != restore.jobID || !restore.state.isActive {
                effects.insert(.stopMessageStream)
            }
            if restore.state.isActive, !wasActive || previousJobID != restore.jobID {
                effects.insert(.startMessageStream)
            }
            return effects

        case .replySubmitted:
            guard canSendReply else { return [] }
            state = .running
            return []

        case let .replyFailed(previousState):
            guard state == .running,
                  previousState == .waitingForInput
            else {
                return []
            }
            state = previousState
            return []

        case .cancelRequested:
            guard canCancel else { return [] }
            state = .cancelling
            cancellationPending = true
            endedAt = ISO8601DateFormatter().string(from: Date())
            return []

        case .cancelConfirmed:
            guard state == .cancelling else { return [] }
            state = .cancelled
            cancellationPending = false
            progress = 1
            return [.stopMessageStream, .refreshSnapshot]

        case .cancelFailed:
            guard state == .cancelling else { return [] }
            state = Self.state(for: messages)
            if state.isTerminal || state == .idle || state == .starting {
                state = .running
            }
            return []

        case .resetMessageRevision:
            messageRevision = ""
            return []

        case .reset:
            let wasActive = state.isActive
            self = GenerationSession()
            return wasActive ? [.stopMessageStream] : []
        }
    }

    private static func state(for messages: [GenerationMessage]) -> GenerationSessionState {
        if GenerationConversation.needsUserInput(messages) {
            return .waitingForInput
        }
        if GenerationConversation.succeeded(messages) {
            return .succeeded
        }
        if GenerationConversation.cancelled(messages) {
            return .cancelled
        }
        if GenerationConversation.failed(messages) {
            return .failed
        }
        return .running
    }
}
