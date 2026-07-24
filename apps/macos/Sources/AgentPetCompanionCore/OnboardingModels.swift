import Foundation

public enum OnboardingStage: String, Codable, CaseIterable, Equatable, Sendable {
    case choosePet = "choose_pet"
    case connectAgents = "connect_agents"
    case demo
    case completed
    case skipped

    public var isTerminal: Bool {
        self == .completed || self == .skipped
    }

    public func canAdvance(to next: Self) -> Bool {
        switch (self, next) {
        case (.choosePet, .connectAgents),
             (.choosePet, .skipped),
             (.connectAgents, .demo),
             (.connectAgents, .skipped),
             (.demo, .completed),
             (.demo, .skipped):
            true
        default:
            false
        }
    }
}

public struct OnboardingProgress: Codable, Equatable, Sendable {
    public static let schemaVersion = "apc.onboarding-progress.v1"

    public var schemaVersion: String
    public var stage: OnboardingStage

    public init(
        schemaVersion: String = Self.schemaVersion,
        stage: OnboardingStage = .choosePet
    ) {
        self.schemaVersion = schemaVersion
        self.stage = stage
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case stage
    }

    public init(from decoder: Decoder) throws {
        try OnboardingClosedDecoding.requireOnlyKeys(
            CodingKeys.self,
            from: decoder
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        guard schemaVersion == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported onboarding progress schema"
            )
        }
        self.schemaVersion = schemaVersion
        stage = try container.decode(OnboardingStage.self, forKey: .stage)
    }
}

public struct VersionedOnboardingProgress: Codable, Equatable, Sendable {
    public var progress: OnboardingProgress
    public var revision: String

    public init(progress: OnboardingProgress, revision: String) {
        self.progress = progress
        self.revision = revision
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case progress
        case revision
    }

    public init(from decoder: Decoder) throws {
        try OnboardingClosedDecoding.requireOnlyKeys(
            CodingKeys.self,
            from: decoder
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        progress = try container.decode(OnboardingProgress.self, forKey: .progress)
        revision = try container.decode(String.self, forKey: .revision)
        guard !revision.isEmpty,
              revision.allSatisfy(\.isNumber),
              UInt64(revision) != nil
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .revision,
                in: container,
                debugDescription: "Onboarding revision must be a decimal UInt64 string"
            )
        }
    }
}

public enum OnboardingDemoPhase: String, CaseIterable, Equatable, Sendable {
    case thinking
    case working
    case needsAttention = "needs_attention"
    case done

    public var lifecycleState: ProductLifecycleState {
        switch self {
        case .thinking: .start
        case .working: .tool
        case .needsAttention: .waiting
        case .done: .done
        }
    }
}

public struct OnboardingDemoSequence: Equatable, Sendable {
    public private(set) var phase: OnboardingDemoPhase

    public init(phase: OnboardingDemoPhase = .thinking) {
        self.phase = phase
    }

    public var isComplete: Bool {
        phase == .done
    }

    @discardableResult
    public mutating func advance() -> OnboardingDemoPhase {
        let phases = OnboardingDemoPhase.allCases
        guard let currentIndex = phases.firstIndex(of: phase),
              currentIndex + 1 < phases.count
        else {
            return phase
        }
        phase = phases[currentIndex + 1]
        return phase
    }

    public mutating func reset() {
        phase = .thinking
    }
}

public struct OnboardingAgentPresentation: Equatable, Sendable, Identifiable {
    public var source: AgentSource
    public var health: AgentConnectionHealthState
    public var primaryAction: AgentConnectionPrimaryAction

    public init?(
        source: AgentSource,
        health: AgentConnectionHealthState,
        primaryAction: AgentConnectionPrimaryAction
    ) {
        guard health != .checking else { return nil }
        self.source = source
        self.health = health
        self.primaryAction = primaryAction
    }

    public var id: AgentSource { source }
}

public enum OnboardingConnectionSceneState: Equatable, Sendable {
    case checking
    case noAgents
    case agents([OnboardingAgentPresentation])
}

public enum OnboardingFlowAvailability: Equatable, Sendable {
    case ready
    case serviceUnavailable
}

public enum OnboardingPrimaryAction: Equatable, Sendable {
    case confirmPet
    case continueToDemo
    case finish
}

public struct OnboardingFlowPresentation: Equatable, Sendable {
    public var progress: OnboardingProgress
    public var availability: OnboardingFlowAvailability
    public var pets: [PetSummary]
    public var selectedPetID: String?
    public var unavailablePetIDs: Set<String>
    public var connectionState: OnboardingConnectionSceneState
    public var demoSequence: OnboardingDemoSequence

    public init(
        progress: OnboardingProgress,
        availability: OnboardingFlowAvailability,
        pets: [PetSummary],
        selectedPetID: String?,
        unavailablePetIDs: Set<String> = [],
        connectionState: OnboardingConnectionSceneState,
        demoSequence: OnboardingDemoSequence
    ) {
        self.progress = progress
        self.availability = availability
        let candidates = Dictionary(
            pets
                .filter(\.isIncludedCompanionCandidate)
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let orderedCandidates = PetSummary.includedCompanionIDs.compactMap {
            candidates[$0]
        }
        let normalizedUnavailablePetIDs = unavailablePetIDs.intersection(
            Set(orderedCandidates.map(\.id))
        )
        self.pets = orderedCandidates
        self.unavailablePetIDs = normalizedUnavailablePetIDs
        self.selectedPetID = orderedCandidates.contains {
            $0.id == selectedPetID
                && !normalizedUnavailablePetIDs.contains($0.id)
        }
            ? selectedPetID
            : nil
        self.connectionState = connectionState
        self.demoSequence = demoSequence
    }

    public var primaryAction: OnboardingPrimaryAction? {
        guard availability == .ready else { return nil }
        switch progress.stage {
        case .choosePet:
            guard let selectedPetID,
                  pets.contains(where: { $0.id == selectedPetID }),
                  !unavailablePetIDs.contains(selectedPetID)
            else {
                return nil
            }
            return .confirmPet
        case .connectAgents:
            return .continueToDemo
        case .demo:
            return demoSequence.isComplete ? .finish : nil
        case .completed, .skipped:
            return nil
        }
    }

    public var allowsSkip: Bool {
        availability == .ready && !progress.stage.isTerminal
    }

    public var allowsClose: Bool {
        !progress.stage.isTerminal
    }
}

private enum OnboardingClosedDecoding {
    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    static func requireOnlyKeys<Key>(
        _ keyType: Key.Type,
        from decoder: Decoder
    ) throws where Key: CodingKey & CaseIterable {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let allowed = Set(keyType.allCases.map(\.stringValue))
        let unknown = container.allKeys
            .map(\.stringValue)
            .filter { !allowed.contains($0) }
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown onboarding fields: \(unknown.sorted())"
                )
            )
        }
    }
}
