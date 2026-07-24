import Foundation

/// Closed product meaning for the seven authored pet states.
///
/// Stored protocol/package names remain the raw values. UI code consumes this
/// type instead of interpreting arbitrary state strings or localized copy.
public enum ProductLifecycleState: String, CaseIterable, Codable, Hashable, Sendable {
    case idle
    case start
    case tool
    case waiting
    case review
    case done
    case failed

    public init(eventKind: AgentEventKind) {
        switch eventKind {
        case .start: self = .start
        case .tool: self = .tool
        case .waiting: self = .waiting
        case .review: self = .review
        case .done: self = .done
        case .failed: self = .failed
        }
    }
}

/// Describes only what destination a session action can truthfully promise.
/// Routing payloads remain separate and are independently validated.
public enum NavigationCapability: String, CaseIterable, Codable, Hashable, Sendable {
    case exactSession = "exact_session"
    case agentHost = "agent_host"
    case unavailable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .unavailable
    }
}

/// Aggregate connection meaning used by the ordinary Agent Connections page.
public enum AgentConnectionHealthState: String, CaseIterable, Hashable, Sendable {
    case notChecked
    case checking
    case connected
    case needsRepair
    case unavailable
}

/// Evidence from a real Agent task is deliberately independent from local
/// connector health. A healthy local installation must never be presented as
/// broken merely because the user has not run a qualifying task yet.
public enum AgentTaskVerificationState: String, CaseIterable, Hashable, Sendable {
    case notRun
    case awaitingTask
    case verified
}

/// Product-level message policies. `custom` is derived when stored event
/// switches do not exactly match one of the three authored presets.
public enum AttentionPreset: String, CaseIterable, Identifiable, Hashable, Sendable {
    case onlyWhenNeeded = "only_when_needed"
    case standard
    case allActivity = "all_activity"
    case custom

    public var id: String { rawValue }

    public var enabledEvents: Set<AgentEventKind>? {
        switch self {
        case .onlyWhenNeeded:
            [.waiting, .review, .failed]
        case .standard:
            [.start, .waiting, .review, .done, .failed]
        case .allActivity:
            Set(AgentEventKind.allCases)
        case .custom:
            nil
        }
    }

    public static func resolve(events: [AgentEventKind: Bool]) -> Self {
        let enabled = Set(AgentEventKind.allCases.filter { events[$0] == true })
        return [.onlyWhenNeeded, .standard, .allActivity]
            .first { $0.enabledEvents == enabled } ?? .custom
    }

    public func applying(to events: [AgentEventKind: Bool]) -> [AgentEventKind: Bool] {
        guard let enabledEvents else { return events }
        return Dictionary(
            uniqueKeysWithValues: AgentEventKind.allCases.map {
                ($0, enabledEvents.contains($0))
            }
        )
    }
}

public struct ConfigurationPresentation: Equatable, Sendable {
    public let attentionPreset: AttentionPreset
    public let supportedPlaybackProfiles: [FpsProfile]
    public let selectedPlaybackProfile: FpsProfile

    public init(behavior: BehaviorSettings, activePet: PetSummary?) {
        attentionPreset = .resolve(events: behavior.events)
        supportedPlaybackProfiles = activePet?.supportedFPSProfiles ?? [.standard]
        selectedPlaybackProfile = supportedPlaybackProfiles.contains(behavior.fpsProfile)
            ? behavior.fpsProfile
            : .standard
    }
}

public extension BehaviorSettings {
    var attentionPreset: AttentionPreset {
        .resolve(events: events)
    }

    func applyingAttentionPreset(_ preset: AttentionPreset) -> Self {
        var next = self
        next.events = preset.applying(to: events)
        return next
    }
}

public enum PetLibraryPrimaryAction: Hashable, Sendable {
    case usePet
    case createPet
    case importPet
    case unavailable
}

public enum PetMakerPrimaryAction: Hashable, Sendable {
    case createPet
    case sendReply
    case cancel
    case retry
    case reselectReferences
    case usePet
    case continueEditing
    case unavailable
}

public enum AgentConnectionPrimaryAction: Hashable, Sendable {
    case connect
    case repair
    case verify
    case retry
    case unavailable
}

public enum ServiceDiagnosticsPrimaryAction: Hashable, Sendable {
    case refresh
    case recover
    case retry
    case unavailable
}
