import Foundation

public struct GenerationInputOption: Codable, Hashable, Sendable {
    public var label: String
    public var description: String?
}

public struct GenerationInputQuestion: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var prompt: String
    public var options: [GenerationInputOption]
    public var allowsFreeform: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case prompt
        case options
        case allowsFreeform = "allows_freeform"
    }
}

public struct GenerationMessagePayload: Codable, Hashable, Sendable {
    public enum PayloadType: String, Codable, Hashable, Sendable {
        case inputRequest = "input_request"
        case result
    }

    public var payloadType: PayloadType
    public var requestID: String?
    public var questions: [GenerationInputQuestion]?
    public var resultPetID: String?
    public var revisionID: String?

    enum CodingKeys: String, CodingKey {
        case payloadType = "payload_type"
        case requestID = "request_id"
        case questions
        case resultPetID = "result_pet_id"
        case revisionID = "revision_id"
    }
}

public struct GenerationMessage: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var jobID: String?
    public var sequence: UInt64?
    public var role: String
    public var content: String
    public var progress: Double
    public var createdAt: String
    public var kind: String?
    public var payload: GenerationMessagePayload?

    public init(id: String = UUID().uuidString, jobID: String? = nil, sequence: UInt64? = nil, role: String, content: String, progress: Double, createdAt: String, kind: String? = nil, payload: GenerationMessagePayload? = nil) {
        self.id = id
        self.jobID = jobID
        self.sequence = sequence
        self.role = role
        self.content = content
        self.progress = progress
        self.createdAt = createdAt
        self.kind = kind
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case id
        case jobID = "job_id"
        case sequence
        case role
        case content
        case progress
        case createdAt = "created_at"
        case kind
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        progress = try container.decode(Double.self, forKey: .progress)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        jobID = try container.decodeIfPresent(String.self, forKey: .jobID)
        sequence = try container.decodeIfPresent(UInt64.self, forKey: .sequence)
        payload = try container.decodeIfPresent(GenerationMessagePayload.self, forKey: .payload)
        let suppliedID = try container.decodeIfPresent(String.self, forKey: .id)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        id = suppliedID.flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.legacyID(
                role: role,
                content: content,
                progress: progress,
                createdAt: createdAt,
                kind: kind
            )
    }

    private static func legacyID(
        role: String,
        content: String,
        progress: Double,
        createdAt: String,
        kind: String?
    ) -> String {
        let canonical = [
            role,
            content,
            String(progress.bitPattern, radix: 16),
            createdAt,
            kind ?? "",
        ].joined(separator: "\u{1F}")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "msg_legacy_\(String(hash, radix: 16))"
    }
}

public enum GenerationConversation {
    private static let completedKind = "generation_completed"
    private static let failedKind = "generation_failed"
    private static let canceledKind = "generation_canceled"
    private static let inputRequestKind = "input_request"
    private static let terminalKinds: Set<String> = [completedKind, failedKind, canceledKind]
    private static let briefKind = "generation_activity_brief"
    private static let generatingKind = "generation_activity_generating"
    private static let processingKind = "generation_activity_processing"
    private static let validatingKind = "generation_activity_validating"
    private static let importingKind = "generation_activity_importing"
    private static let checkpointKind = "generation_checkpoint"
    private static let heartbeatKind = "generation_heartbeat"
    private static let resumedKind = "generation_resumed"

    public static func succeeded(_ messages: [GenerationMessage]) -> Bool {
        latestTerminalKind(messages) == completedKind
    }

    public static func needsUserInput(_ messages: [GenerationMessage]) -> Bool {
        guard let lastMessage = messages.last else { return false }
        return lastMessage.role == "assistant" && lastMessage.kind == inputRequestKind
    }

    public static func terminalUnsuccessful(_ messages: [GenerationMessage]) -> Bool {
        guard let kind = latestTerminalKind(messages) else { return false }
        return kind == failedKind || kind == canceledKind
    }

    public static func cancelled(_ messages: [GenerationMessage]) -> Bool {
        latestTerminalKind(messages) == canceledKind
    }

    public static func failed(_ messages: [GenerationMessage]) -> Bool {
        latestTerminalKind(messages) == failedKind
    }

    public static func canSendReply(_ messages: [GenerationMessage]) -> Bool {
        needsUserInput(messages)
    }

    public static func activeStepIndex(
        messages: [GenerationMessage],
        progress: Double,
        operation: GenerationOperation = .create
    ) -> Int {
        if succeeded(messages) {
            return 3
        }
        if needsUserInput(messages) {
            return operation == .modify ? 1 : 0
        }
        let typedStep = runtimePhase(messages)?.stepIndex(for: operation)
        if terminalUnsuccessful(messages) {
            if let typedStep { return typedStep }
            let lastActiveProgress = messages.reversed().first { message in
                guard let kind = message.kind else { return true }
                return !terminalKinds.contains(kind)
            }?.progress
            let fallbackProgress = failed(messages) ? min(progress, 0.95) : 0
            return stepIndex(for: lastActiveProgress ?? fallbackProgress)
        }

        if let typedStep { return typedStep }
        return stepIndex(for: progress)
    }

    public static func runtimePhase(
        _ messages: [GenerationMessage]
    ) -> GenerationRuntimePhase? {
        for message in messages.reversed() {
            switch message.kind {
            case importingKind:
                return .importing
            case validatingKind:
                return .validating
            case generatingKind, processingKind, checkpointKind:
                return .producing
            case briefKind:
                return .brief
            default:
                continue
            }
        }
        return nil
    }

    public static func currentActivity(
        _ messages: [GenerationMessage]
    ) -> GenerationMessage? {
        let activityKinds: Set<String> = [
            briefKind,
            generatingKind,
            processingKind,
            validatingKind,
            importingKind,
            checkpointKind,
            resumedKind,
            "generation_progress",
            "generation_started",
        ]
        return messages.reversed().first { message in
            message.kind.map(activityKinds.contains) == true
                && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public static func checkpointCount(_ messages: [GenerationMessage]) -> Int {
        messages.reduce(into: 0) { count, message in
            if message.kind == checkpointKind { count += 1 }
        }
    }

    public static func heartbeatMessage(
        _ messages: [GenerationMessage]
    ) -> GenerationMessage? {
        messages.reversed().first { message in
            message.kind == heartbeatKind
        } ?? messages.reversed().first { message in
            guard !message.createdAt.isEmpty else { return false }
            return message.role == "assistant"
        }
    }

    public static func startedMessage(
        _ messages: [GenerationMessage]
    ) -> GenerationMessage? {
        messages.first { !$0.createdAt.isEmpty }
    }

    private static func stepIndex(for progress: Double) -> Int {
        switch progress {
        case 0..<0.25:
            return 0
        case 0.25..<0.60:
            return 1
        case 0.60..<0.96:
            return 2
        default:
            return 3
        }
    }

    private static func latestTerminalKind(_ messages: [GenerationMessage]) -> String? {
        guard let message = messages.last, message.role == "assistant" else {
            return nil
        }
        guard let kind = message.kind, terminalKinds.contains(kind) else {
            return nil
        }
        return kind
    }
}

public enum GenerationRuntimePhase: String, Codable, Hashable, Sendable {
    case brief
    case producing
    case validating
    case importing

    fileprivate func stepIndex(for operation: GenerationOperation) -> Int {
        switch (operation, self) {
        case (.create, .brief): 0
        case (.create, .producing): 1
        case (.create, .validating): 2
        case (.create, .importing): 3
        case (.modify, .brief): 1
        case (.modify, .producing): 2
        case (.modify, .validating), (.modify, .importing): 3
        }
    }
}

public enum GenerationOperation: String, Codable, Hashable, Sendable {
    case create
    case modify
}

public struct GenerationValidationSummary: Codable, Equatable, Sendable {
    public var ok: Bool
    public var stateCount: Int
    public var frameCount: Int
    public var warningCount: Int

    public init(ok: Bool, stateCount: Int, frameCount: Int, warningCount: Int) {
        self.ok = ok
        self.stateCount = max(0, stateCount)
        self.frameCount = max(0, frameCount)
        self.warningCount = max(0, warningCount)
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case stateCount = "state_count"
        case frameCount = "frame_count"
        case warningCount = "warning_count"
    }
}

public struct GenerationResultMetadata: Codable, Equatable, Sendable {
    public var resultPetID: String?
    public var revisionID: String?
    public var validationSummary: GenerationValidationSummary?

    public init(
        resultPetID: String? = nil,
        revisionID: String? = nil,
        validationSummary: GenerationValidationSummary? = nil
    ) {
        self.resultPetID = resultPetID
        self.revisionID = revisionID
        self.validationSummary = validationSummary
    }

    public var isEmpty: Bool {
        resultPetID == nil && revisionID == nil && validationSummary == nil
    }

    enum CodingKeys: String, CodingKey {
        case resultPetID = "result_pet_id"
        case revisionID = "revision_id"
        case validationSummary = "validation_summary"
    }
}

public struct PetRevisionHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    public var revisionID: String
    public var current: Bool
    public var validated: Bool
    public var coverPath: String?
    public var validationSummary: GenerationValidationSummary?

    public var id: String { revisionID }

    public init(
        revisionID: String,
        current: Bool,
        validated: Bool,
        coverPath: String? = nil,
        validationSummary: GenerationValidationSummary? = nil
    ) {
        self.revisionID = revisionID
        self.current = current
        self.validated = validated
        self.coverPath = coverPath
        self.validationSummary = validationSummary
    }

    enum CodingKeys: String, CodingKey {
        case revisionID = "revision_id"
        case current
        case validated
        case coverPath = "cover_path"
        case validationSummary = "validation_summary"
    }
}

public enum GenerationJobHistoryStatus: String, Codable, Equatable, Sendable {
    case pending
    case running
    case waitingForUser = "waiting_for_user"
    case completed
    case failed
    case canceled
}

public struct GenerationJobHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    public var jobID: String
    public var status: GenerationJobHistoryStatus
    public var operation: GenerationOperation
    public var baselineRevisionID: String?
    public var revisionID: String?
    public var validationSummary: GenerationValidationSummary?
    public var createdAt: String
    public var updatedAt: String

    public var id: String { jobID }

    public init(
        jobID: String,
        status: GenerationJobHistoryStatus,
        operation: GenerationOperation,
        baselineRevisionID: String? = nil,
        revisionID: String? = nil,
        validationSummary: GenerationValidationSummary? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.jobID = jobID
        self.status = status
        self.operation = operation
        self.baselineRevisionID = baselineRevisionID
        self.revisionID = revisionID
        self.validationSummary = validationSummary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case status
        case operation
        case baselineRevisionID = "baseline_revision_id"
        case revisionID = "revision_id"
        case validationSummary = "validation_summary"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct PetHistorySnapshot: Codable, Equatable, Sendable {
    public var ok: Bool
    public var petID: String
    public var currentRevisionID: String?
    public var revisions: [PetRevisionHistoryRecord]
    public var jobs: [GenerationJobHistoryRecord]
    public var truncated: Bool

    public init(
        ok: Bool = true,
        petID: String,
        currentRevisionID: String? = nil,
        revisions: [PetRevisionHistoryRecord] = [],
        jobs: [GenerationJobHistoryRecord] = [],
        truncated: Bool = false
    ) {
        self.ok = ok
        self.petID = petID
        self.currentRevisionID = currentRevisionID
        self.revisions = revisions
        self.jobs = jobs
        self.truncated = truncated
    }

    public var hasCreationHistory: Bool { !jobs.isEmpty }

    enum CodingKeys: String, CodingKey {
        case ok
        case petID = "pet_id"
        case currentRevisionID = "current_revision_id"
        case revisions
        case jobs
        case truncated
    }
}

public struct GenerationStudioHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    public var jobID: String
    public var status: GenerationJobHistoryStatus
    public var operation: GenerationOperation
    public var visibleTitle: String?
    public var briefPreview: String
    public var style: String
    public var quality: QualityLevel
    public var referenceCount: Int
    public var resultPetID: String?
    public var retryOfJobID: String?
    public var createdAt: String
    public var updatedAt: String
    public var startedAt: String?
    public var endedAt: String?
    public var progress: Double?
    public var recoverable: Bool?
    public var pauseReason: String?
    public var cancellationPending: Bool?
    public var capabilities: GenerationSessionCapabilities?

    public var id: String { jobID }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case status
        case operation
        case visibleTitle = "visible_title"
        case briefPreview = "brief_preview"
        case style
        case quality
        case referenceCount = "reference_count"
        case resultPetID = "result_pet_id"
        case retryOfJobID = "retry_of_job_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case progress
        case recoverable
        case pauseReason = "pause_reason"
        case cancellationPending = "cancellation_pending"
        case capabilities
    }
}

public struct GenerationSessionCapabilities: Codable, Equatable, Hashable, Sendable {
    public var canReply: Bool
    public var canResume: Bool
    public var canCancel: Bool
    public var canOpenResult: Bool
    public var canOpenSession: Bool
    public var canDelete: Bool

    public init(
        canReply: Bool = false,
        canResume: Bool = false,
        canCancel: Bool = false,
        canOpenResult: Bool = false,
        canOpenSession: Bool = false,
        canDelete: Bool = false
    ) {
        self.canReply = canReply
        self.canResume = canResume
        self.canCancel = canCancel
        self.canOpenResult = canOpenResult
        self.canOpenSession = canOpenSession
        self.canDelete = canDelete
    }

    enum CodingKeys: String, CodingKey {
        case canReply = "can_reply"
        case canResume = "can_resume"
        case canCancel = "can_cancel"
        case canOpenResult = "can_open_result"
        case canOpenSession = "can_open_session"
        case canDelete = "can_delete"
    }
}

public struct GenerationStudioHistorySnapshot: Codable, Equatable, Sendable {
    public var ok: Bool
    public var jobs: [GenerationStudioHistoryRecord]
    public var truncated: Bool

    public init(
        ok: Bool = true,
        jobs: [GenerationStudioHistoryRecord] = [],
        truncated: Bool = false
    ) {
        self.ok = ok
        self.jobs = jobs
        self.truncated = truncated
    }
}

public struct GenerationStudioHistoryDeleteReceipt: Codable, Equatable, Sendable {
    public var ok: Bool
    public var jobID: String
    public var deletedStatus: GenerationJobHistoryStatus
    public var deletedMessageCount: Int
    public var workspaceRemoved: Bool
    public var retainedResultPetID: String?
    public var retryChildrenRelinked: Int
    public var stateRevision: String

    public init(
        ok: Bool = true,
        jobID: String,
        deletedStatus: GenerationJobHistoryStatus,
        deletedMessageCount: Int,
        workspaceRemoved: Bool,
        retainedResultPetID: String? = nil,
        retryChildrenRelinked: Int,
        stateRevision: String
    ) {
        self.ok = ok
        self.jobID = jobID
        self.deletedStatus = deletedStatus
        self.deletedMessageCount = max(0, deletedMessageCount)
        self.workspaceRemoved = workspaceRemoved
        self.retainedResultPetID = retainedResultPetID
        self.retryChildrenRelinked = max(0, retryChildrenRelinked)
        self.stateRevision = stateRevision
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case jobID = "job_id"
        case deletedStatus = "deleted_status"
        case deletedMessageCount = "deleted_message_count"
        case workspaceRemoved = "workspace_removed"
        case retainedResultPetID = "retained_result_pet_id"
        case retryChildrenRelinked = "retry_children_relinked"
        case stateRevision = "state_revision"
    }
}

public enum GenerationStudioSessionAvailability: String, Codable, Equatable, Sendable {
    case notCreated = "not_created"
    case available
    case archived
    case missing
    case unavailable
}

public struct GenerationStudioSessionNavigation: Codable, Equatable, Sendable {
    public var availability: GenerationStudioSessionAvailability
    public var canOpen: Bool
    public var routableSessionID: String?
    public var name: String?

    public init(
        availability: GenerationStudioSessionAvailability,
        canOpen: Bool = false,
        routableSessionID: String? = nil,
        name: String? = nil
    ) {
        self.availability = availability
        self.canOpen = canOpen
        self.routableSessionID = routableSessionID
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case availability
        case canOpen = "can_open"
        case routableSessionID = "routable_session_id"
        case name
    }
}

public struct GenerationStudioHistoryDetail: Codable, Equatable, Sendable {
    public var ok: Bool
    public var found: Bool
    public var jobID: String?
    public var status: GenerationJobHistoryStatus?
    public var operation: GenerationOperation?
    public var visibleTitle: String?
    public var description: String?
    public var style: String?
    public var quality: QualityLevel?
    public var referenceCount: Int
    public var resultPetID: String?
    public var retryOfJobID: String?
    public var revisionID: String?
    public var validationSummary: GenerationValidationSummary?
    public var createdAt: String?
    public var updatedAt: String?
    public var startedAt: String?
    public var endedAt: String?
    public var progress: Double?
    public var recoverable: Bool?
    public var failureCode: String?
    public var pauseReason: String?
    public var cancellationPending: Bool?
    public var progressMessages: [GenerationMessage]
    public var latestCodexExcerpt: String?
    public var messageCount: Int
    public var messagesTruncated: Bool
    public var session: GenerationStudioSessionNavigation
    public var capabilities: GenerationSessionCapabilities?

    enum CodingKeys: String, CodingKey {
        case ok
        case found
        case jobID = "job_id"
        case status
        case operation
        case visibleTitle = "visible_title"
        case description
        case style
        case quality
        case referenceCount = "reference_count"
        case resultPetID = "result_pet_id"
        case retryOfJobID = "retry_of_job_id"
        case revisionID = "revision_id"
        case validationSummary = "validation_summary"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case progress
        case recoverable
        case failureCode = "failure_code"
        case pauseReason = "pause_reason"
        case cancellationPending = "cancellation_pending"
        case progressMessages = "progress_messages"
        case latestCodexExcerpt = "latest_codex_excerpt"
        case messageCount = "message_count"
        case messagesTruncated = "messages_truncated"
        case session
        case capabilities
    }
}

public struct GenerationMessagesPage: Codable, Equatable, Sendable {
    public var ok: Bool
    public var jobID: String
    public var messages: [GenerationMessage]
    public var hasMore: Bool
    public var nextBeforeSequence: UInt64?
    public var revision: String

    enum CodingKeys: String, CodingKey {
        case ok
        case jobID = "job_id"
        case messages
        case hasMore = "has_more"
        case nextBeforeSequence = "next_before_sequence"
        case revision
    }
}

public struct GenerationHistory: Codable, Sendable {
    public var found: Bool
    public var petId: String
    public var jobId: String?
    public var status: GenerationJobHistoryStatus?
    public var sessionId: String?
    public var resultPetId: String?
    public var revisionId: String?
    public var validationSummary: GenerationValidationSummary?
    public var retryOfJobId: String?
    public var operation: GenerationOperation?
    public var baselineRevisionID: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var form: GenerationForm?
    public var referenceReselectionCount: Int
    public var messages: [GenerationMessage]

    public init(
        found: Bool,
        petId: String,
        jobId: String? = nil,
        status: GenerationJobHistoryStatus? = nil,
        sessionId: String? = nil,
        resultPetId: String? = nil,
        revisionId: String? = nil,
        validationSummary: GenerationValidationSummary? = nil,
        retryOfJobId: String? = nil,
        operation: GenerationOperation? = nil,
        baselineRevisionID: String? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        form: GenerationForm? = nil,
        referenceReselectionCount: Int = 0,
        messages: [GenerationMessage] = []
    ) {
        self.found = found
        self.petId = petId
        self.jobId = jobId
        self.status = status
        self.sessionId = sessionId
        self.resultPetId = resultPetId
        self.revisionId = revisionId
        self.validationSummary = validationSummary
        self.retryOfJobId = retryOfJobId
        self.operation = operation
        self.baselineRevisionID = baselineRevisionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.form = form
        self.referenceReselectionCount = referenceReselectionCount
        self.messages = messages
    }

    enum CodingKeys: String, CodingKey {
        case found
        case petId = "pet_id"
        case jobId = "job_id"
        case status
        case sessionId = "session_id"
        case resultPetId = "result_pet_id"
        case revisionId = "revision_id"
        case validationSummary = "validation_summary"
        case retryOfJobId = "retry_of_job_id"
        case operation
        case baselineRevisionID = "baseline_revision_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case form
        case referenceReselectionCount = "reference_reselection_count"
        case messages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        found = try container.decode(Bool.self, forKey: .found)
        petId = try container.decode(String.self, forKey: .petId)
        jobId = try container.decodeIfPresent(String.self, forKey: .jobId)
        let rawStatus = try container.decodeIfPresent(String.self, forKey: .status)
        status = rawStatus == "cancelled"
            ? .canceled
            : rawStatus.flatMap(GenerationJobHistoryStatus.init(rawValue:))
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        resultPetId = try container.decodeIfPresent(String.self, forKey: .resultPetId)
        revisionId = try container.decodeIfPresent(String.self, forKey: .revisionId)
        validationSummary = try container.decodeIfPresent(
            GenerationValidationSummary.self,
            forKey: .validationSummary
        )
        retryOfJobId = try container.decodeIfPresent(String.self, forKey: .retryOfJobId)
        operation = try container.decodeIfPresent(GenerationOperation.self, forKey: .operation)
        baselineRevisionID = try container.decodeIfPresent(
            String.self,
            forKey: .baselineRevisionID
        )
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        form = try container.decodeIfPresent(GenerationForm.self, forKey: .form)
        let decodedReferenceReselectionCount = try container.decodeIfPresent(
            Int.self,
            forKey: .referenceReselectionCount
        ) ?? 0
        guard (0 ... 4).contains(decodedReferenceReselectionCount) else {
            throw DecodingError.dataCorruptedError(
                forKey: .referenceReselectionCount,
                in: container,
                debugDescription: "reference_reselection_count must be between 0 and 4"
            )
        }
        referenceReselectionCount = decodedReferenceReselectionCount
        guard decodedReferenceReselectionCount == 0 || form?.referenceImages.isEmpty != false else {
            throw DecodingError.dataCorruptedError(
                forKey: .referenceReselectionCount,
                in: container,
                debugDescription: "a recovery projection cannot mix safe paths with reselection slots"
            )
        }
        messages = try container.decodeIfPresent([GenerationMessage].self, forKey: .messages) ?? []
    }
}

/// Private, bounded Maker-session recovery projection. Unlike
/// `GenerationHistory`, this shape does not require a result pet ID: failed or
/// canceled create jobs must remain recoverable after the App restarts.
public struct LatestGenerationSessionSnapshot: Codable, Equatable, Sendable {
    public var found: Bool
    public var jobID: String?
    public var status: GenerationJobHistoryStatus?
    public var resultPetID: String?
    public var revisionID: String?
    public var validationSummary: GenerationValidationSummary?
    public var operation: GenerationOperation?
    public var baselineRevisionID: String?
    public var form: GenerationForm?
    public var referenceReselectionCount: Int
    public var messageRevision: String
    public var heartbeatAt: String?
    public var startedAt: String?
    public var endedAt: String?
    public var recoverable: Bool
    public var failureCode: String?
    public var pauseReason: String?
    public var cancellationPending: Bool
    public var capabilities: GenerationSessionCapabilities?
    public var messages: [GenerationMessage]

    public init(
        found: Bool,
        jobID: String? = nil,
        status: GenerationJobHistoryStatus? = nil,
        resultPetID: String? = nil,
        revisionID: String? = nil,
        validationSummary: GenerationValidationSummary? = nil,
        operation: GenerationOperation? = nil,
        baselineRevisionID: String? = nil,
        form: GenerationForm? = nil,
        referenceReselectionCount: Int = 0,
        messageRevision: String = "",
        heartbeatAt: String? = nil,
        startedAt: String? = nil,
        endedAt: String? = nil,
        recoverable: Bool = false,
        failureCode: String? = nil,
        pauseReason: String? = nil,
        cancellationPending: Bool = false,
        capabilities: GenerationSessionCapabilities? = nil,
        messages: [GenerationMessage] = []
    ) {
        self.found = found
        self.jobID = jobID
        self.status = status
        self.resultPetID = resultPetID
        self.revisionID = revisionID
        self.validationSummary = validationSummary
        self.operation = operation
        self.baselineRevisionID = baselineRevisionID
        self.form = form
        self.referenceReselectionCount = referenceReselectionCount
        self.messageRevision = messageRevision
        self.heartbeatAt = heartbeatAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.recoverable = recoverable
        self.failureCode = failureCode
        self.pauseReason = pauseReason
        self.cancellationPending = cancellationPending
        self.capabilities = capabilities
        self.messages = messages
    }

    enum CodingKeys: String, CodingKey {
        case found
        case jobID = "job_id"
        case status
        case resultPetID = "result_pet_id"
        case revisionID = "revision_id"
        case validationSummary = "validation_summary"
        case operation
        case baselineRevisionID = "baseline_revision_id"
        case form
        case referenceReselectionCount = "reference_reselection_count"
        case messageRevision = "message_revision"
        case heartbeatAt = "heartbeat_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case recoverable
        case failureCode = "failure_code"
        case pauseReason = "pause_reason"
        case cancellationPending = "cancellation_pending"
        case capabilities
        case messages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        found = try container.decode(Bool.self, forKey: .found)
        jobID = try container.decodeIfPresent(String.self, forKey: .jobID)
        let rawStatus = try container.decodeIfPresent(String.self, forKey: .status)
        status = rawStatus == "cancelled"
            ? .canceled
            : rawStatus.flatMap(GenerationJobHistoryStatus.init(rawValue:))
        resultPetID = try container.decodeIfPresent(String.self, forKey: .resultPetID)
        revisionID = try container.decodeIfPresent(String.self, forKey: .revisionID)
        validationSummary = try container.decodeIfPresent(
            GenerationValidationSummary.self,
            forKey: .validationSummary
        )
        operation = try container.decodeIfPresent(GenerationOperation.self, forKey: .operation)
        baselineRevisionID = try container.decodeIfPresent(
            String.self,
            forKey: .baselineRevisionID
        )
        form = try container.decodeIfPresent(GenerationForm.self, forKey: .form)
        let decodedReferenceReselectionCount = try container.decodeIfPresent(
            Int.self,
            forKey: .referenceReselectionCount
        ) ?? 0
        guard (0 ... 4).contains(decodedReferenceReselectionCount) else {
            throw DecodingError.dataCorruptedError(
                forKey: .referenceReselectionCount,
                in: container,
                debugDescription: "reference_reselection_count must be between 0 and 4"
            )
        }
        referenceReselectionCount = decodedReferenceReselectionCount
        guard decodedReferenceReselectionCount == 0 || form?.referenceImages.isEmpty != false else {
            throw DecodingError.dataCorruptedError(
                forKey: .referenceReselectionCount,
                in: container,
                debugDescription: "a recovery projection cannot mix safe paths with reselection slots"
            )
        }
        messageRevision = try container.decodeIfPresent(String.self, forKey: .messageRevision) ?? ""
        heartbeatAt = try container.decodeIfPresent(String.self, forKey: .heartbeatAt)
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(String.self, forKey: .endedAt)
        recoverable = try container.decodeIfPresent(Bool.self, forKey: .recoverable) ?? false
        failureCode = try container.decodeIfPresent(String.self, forKey: .failureCode)
        pauseReason = try container.decodeIfPresent(String.self, forKey: .pauseReason)
        cancellationPending = try container.decodeIfPresent(
            Bool.self,
            forKey: .cancellationPending
        ) ?? false
        capabilities = try container.decodeIfPresent(
            GenerationSessionCapabilities.self,
            forKey: .capabilities
        )
        messages = try container.decodeIfPresent([GenerationMessage].self, forKey: .messages) ?? []
    }
}

public enum ActiveGenerationStatus: String, Codable, Hashable, Sendable {
    case pending
    case running
    case waitingForUser = "waiting_for_user"
    case failed
}

public struct ActiveGenerationSnapshot: Codable, Equatable, Sendable {
    public var jobID: String
    public var status: ActiveGenerationStatus
    public var form: GenerationForm
    public var sessionID: String?
    public var resultPetID: String?
    public var operation: GenerationOperation?
    public var baselineRevisionID: String?
    public var ownerInstanceID: String?
    public var heartbeatAt: String
    public var startedAt: String?
    public var endedAt: String?
    public var recoverable: Bool
    public var failureCode: String?
    public var pauseReason: String?
    public var cancellationPending: Bool
    public var capabilities: GenerationSessionCapabilities?
    public var messageRevision: String
    public var referenceReselectionCount: Int
    public var messages: [GenerationMessage]
    public var inputRequest: GenerationMessage?

    public init(
        jobID: String,
        status: ActiveGenerationStatus,
        form: GenerationForm,
        sessionID: String? = nil,
        resultPetID: String? = nil,
        operation: GenerationOperation? = nil,
        baselineRevisionID: String? = nil,
        ownerInstanceID: String? = nil,
        heartbeatAt: String,
        startedAt: String? = nil,
        endedAt: String? = nil,
        recoverable: Bool = false,
        failureCode: String? = nil,
        pauseReason: String? = nil,
        cancellationPending: Bool = false,
        capabilities: GenerationSessionCapabilities? = nil,
        messageRevision: String,
        referenceReselectionCount: Int = 0,
        messages: [GenerationMessage],
        inputRequest: GenerationMessage? = nil
    ) {
        self.jobID = jobID
        self.status = status
        self.form = form
        self.sessionID = sessionID
        self.resultPetID = resultPetID
        self.operation = operation
        self.baselineRevisionID = baselineRevisionID
        self.ownerInstanceID = ownerInstanceID
        self.heartbeatAt = heartbeatAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.recoverable = recoverable
        self.failureCode = failureCode
        self.pauseReason = pauseReason
        self.cancellationPending = cancellationPending
        self.capabilities = capabilities
        self.messageRevision = messageRevision
        self.referenceReselectionCount = referenceReselectionCount
        self.messages = messages
        self.inputRequest = inputRequest
    }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case status
        case form
        case sessionID = "session_id"
        case resultPetID = "result_pet_id"
        case operation
        case baselineRevisionID = "baseline_revision_id"
        case ownerInstanceID = "owner_instance_id"
        case heartbeatAt = "heartbeat_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case recoverable
        case failureCode = "failure_code"
        case pauseReason = "pause_reason"
        case cancellationPending = "cancellation_pending"
        case capabilities
        case messageRevision = "message_revision"
        case referenceReselectionCount = "reference_reselection_count"
        case messages
        case inputRequest = "input_request"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try container.decode(String.self, forKey: .jobID)
        status = try container.decode(ActiveGenerationStatus.self, forKey: .status)
        form = try container.decode(GenerationForm.self, forKey: .form)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        resultPetID = try container.decodeIfPresent(String.self, forKey: .resultPetID)
        operation = try container.decodeIfPresent(GenerationOperation.self, forKey: .operation)
        baselineRevisionID = try container.decodeIfPresent(
            String.self,
            forKey: .baselineRevisionID
        )
        ownerInstanceID = try container.decodeIfPresent(String.self, forKey: .ownerInstanceID)
        heartbeatAt = try container.decode(String.self, forKey: .heartbeatAt)
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(String.self, forKey: .endedAt)
        recoverable = try container.decodeIfPresent(Bool.self, forKey: .recoverable) ?? false
        failureCode = try container.decodeIfPresent(String.self, forKey: .failureCode)
        pauseReason = try container.decodeIfPresent(String.self, forKey: .pauseReason)
        cancellationPending = try container.decodeIfPresent(
            Bool.self,
            forKey: .cancellationPending
        ) ?? false
        capabilities = try container.decodeIfPresent(
            GenerationSessionCapabilities.self,
            forKey: .capabilities
        )
        messageRevision = try container.decode(String.self, forKey: .messageRevision)
        let decodedReferenceReselectionCount = try container.decodeIfPresent(
            Int.self,
            forKey: .referenceReselectionCount
        ) ?? 0
        guard (0 ... 4).contains(decodedReferenceReselectionCount) else {
            throw DecodingError.dataCorruptedError(
                forKey: .referenceReselectionCount,
                in: container,
                debugDescription: "reference_reselection_count must be between 0 and 4"
            )
        }
        referenceReselectionCount = decodedReferenceReselectionCount
        guard decodedReferenceReselectionCount == 0 || form.referenceImages.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .referenceReselectionCount,
                in: container,
                debugDescription: "a recovery projection cannot mix safe paths with reselection slots"
            )
        }
        messages = try container.decodeIfPresent([GenerationMessage].self, forKey: .messages) ?? []
        inputRequest = try container.decodeIfPresent(
            GenerationMessage.self,
            forKey: .inputRequest
        )
    }
}

public struct GenerationForm: Codable, Equatable, Sendable {
    public var description: String
    public var style: String
    public var quality: QualityLevel
    public var referenceImages: [String]

    public init(
        description: String,
        style: String,
        quality: QualityLevel,
        referenceImages: [String]
    ) {
        self.description = description
        self.style = style
        self.quality = quality
        self.referenceImages = referenceImages
    }

    enum CodingKeys: String, CodingKey {
        case description
        case style
        case quality
        case referenceImages = "reference_images"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        description = try container.decode(String.self, forKey: .description)
        style = try container.decode(String.self, forKey: .style)
        quality = try container.decode(QualityLevel.self, forKey: .quality)
        referenceImages = try container.decode([String].self, forKey: .referenceImages)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(description, forKey: .description)
        try container.encode(style, forKey: .style)
        try container.encode(quality, forKey: .quality)
        try container.encode(referenceImages, forKey: .referenceImages)
    }
}
