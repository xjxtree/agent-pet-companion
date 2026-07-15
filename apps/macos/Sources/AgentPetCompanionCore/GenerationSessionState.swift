import Foundation

public enum GenerationSessionState: String, CaseIterable, Codable, Hashable, Sendable {
    case idle
    case starting
    case running
    case waitingForInput
    case cancelling
    case succeeded
    case failed
    case cancelled

    public var isActive: Bool {
        switch self {
        case .starting, .running, .waitingForInput, .cancelling:
            true
        case .idle, .succeeded, .failed, .cancelled:
            false
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled:
            true
        case .idle, .starting, .running, .waitingForInput, .cancelling:
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
    public var operation: GenerationOperation
    public var resultPetID: String?

    public init(
        state: GenerationSessionState,
        jobID: String,
        submittedForm: GenerationForm?,
        messages: [GenerationMessage],
        progress: Double,
        messageRevision: String,
        operation: GenerationOperation = .create,
        resultPetID: String? = nil
    ) {
        self.state = state
        self.jobID = jobID
        self.submittedForm = submittedForm
        self.messages = messages
        self.progress = progress
        self.messageRevision = messageRevision
        self.operation = operation
        self.resultPetID = resultPetID
    }

    public init(snapshot: ActiveGenerationSnapshot) {
        var messages = snapshot.messages
        if let inputRequest = snapshot.inputRequest,
           !messages.contains(where: { $0.id == inputRequest.id }) {
            messages.append(inputRequest)
        }
        state = switch snapshot.status {
        case .pending: .starting
        case .running: .running
        case .waitingForUser: .waitingForInput
        }
        jobID = snapshot.jobID
        submittedForm = snapshot.form
        self.messages = messages
        progress = messages.last?.progress ?? snapshot.inputRequest?.progress ?? 0
        messageRevision = snapshot.messageRevision
        operation = snapshot.operation ?? .create
        resultPetID = snapshot.resultPetID
    }
}

public enum GenerationSessionAction: Equatable, Sendable {
    case startRequested(form: GenerationForm, initialMessage: GenerationMessage)
    case editRequested(
        form: GenerationForm,
        initialMessage: GenerationMessage,
        petID: String
    )
    case retryRequested(form: GenerationForm, initialMessage: GenerationMessage)
    case startAccepted(jobID: String)
    case startFailed(message: GenerationMessage)
    case messagesReceived([GenerationMessage], revision: String?)
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
    public private(set) var operation: GenerationOperation
    public private(set) var resultPetID: String?

    public init(
        state: GenerationSessionState = .idle,
        jobID: String? = nil,
        submittedForm: GenerationForm? = nil,
        messages: [GenerationMessage] = [],
        progress: Double = 0,
        messageRevision: String = "",
        operation: GenerationOperation = .create,
        resultPetID: String? = nil
    ) {
        self.state = state
        self.jobID = jobID
        self.submittedForm = submittedForm
        self.messages = messages
        self.progress = progress
        self.messageRevision = messageRevision
        self.operation = operation
        self.resultPetID = resultPetID
    }

    public var isActive: Bool { state.isActive }

    public var canCancel: Bool {
        jobID != nil && (state == .starting || state == .running || state == .waitingForInput)
    }

    public var canSendReply: Bool {
        jobID != nil && (state == .waitingForInput || state == .succeeded)
    }

    public var canRetry: Bool {
        submittedForm != nil && (state == .failed || state == .cancelled)
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
            operation = .create
            resultPetID = nil
            return []

        case let .editRequested(form, initialMessage, petID):
            guard !state.isActive, !petID.isEmpty else { return [] }
            state = .starting
            jobID = nil
            submittedForm = form
            messages = [initialMessage]
            progress = initialMessage.progress
            messageRevision = ""
            operation = .modify
            resultPetID = petID
            return []

        case let .retryRequested(form, initialMessage):
            guard canRetry, jobID != nil else { return [] }
            state = .starting
            submittedForm = form
            messages = [initialMessage]
            progress = initialMessage.progress
            messageRevision = ""
            // Keep jobID, operation, and resultPetID until the retry RPC is
            // accepted. If transport/startup fails, the same safe retry can be
            // attempted again instead of falling back to a new create job.
            return []

        case let .startAccepted(jobID):
            guard state == .starting else { return [] }
            self.jobID = jobID
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

        case let .restore(restore):
            let previousJobID = jobID
            let wasActive = state.isActive
            state = restore.state
            jobID = restore.jobID
            submittedForm = restore.submittedForm
            messages = restore.messages
            progress = restore.progress
            messageRevision = restore.messageRevision
            operation = restore.operation
            resultPetID = restore.resultPetID
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
                  previousState == .waitingForInput || previousState == .succeeded
            else {
                return []
            }
            state = previousState
            return []

        case .cancelRequested:
            guard canCancel else { return [] }
            state = .cancelling
            return []

        case .cancelConfirmed:
            guard state == .cancelling else { return [] }
            state = .cancelled
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
