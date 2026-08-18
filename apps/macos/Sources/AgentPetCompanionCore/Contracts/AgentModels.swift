import Foundation

public enum AgentSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case codex
    case claudeCode = "claude_code"
    case pi
    case opencode
    case dsh

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .pi: "Pi Coding Agent"
        case .opencode: "OpenCode"
        case .dsh: "DeepSeek Harness"
        }
    }

    public var shortTitle: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude"
        case .pi: "Pi"
        case .opencode: "OpenCode"
        case .dsh: "dsh"
        }
    }
}

public enum AgentEventKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case start
    case thinking
    case plan
    case tool
    case waiting
    case done
    case failed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .start: "开始处理"
        case .thinking: "思考"
        case .plan: "规划"
        case .tool: "执行工具"
        case .waiting: "等待确认"
        case .done: "完成"
        case .failed: "失败"
        }
    }

    /// Renderer-facing mapping to V3 package actions. `start` is a visible
    /// session event with no pet response; Thinking and Plan share the
    /// explicitly named `thinking` action.
    public var petState: String {
        switch self {
        case .start: "idle"
        case .thinking, .plan: "thinking"
        case .tool, .waiting, .done, .failed: rawValue
        }
    }

    public var triggersPetReaction: Bool { self != .start }
}

public struct AgentEventPayload: Codable, Hashable, Sendable {
    public var schemaVersion: String?
    public var externalEventID: String?
    public var sourceEvent: String?
    public var toolName: String?
    public var outcome: String?
    public var diagnostic: Bool?
    public var turnID: String?
    public var sessionActive: Bool?
    public var messageRole: String?
    public var messageContent: String?
    public var activityKind: String?
    public var activityContent: String?
    public var interactionKind: String?
    public var projectLabel: String?
    public var sessionTitle: String?
    public var sessionOpen: Bool?
    public var sessionSurface: String?
    public var terminalApp: String?
    public var sessionOpenURL: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case externalEventID = "external_event_id"
        case sourceEvent = "source_event"
        case toolName = "tool_name"
        case outcome
        case diagnostic
        case turnID = "turn_id"
        case sessionActive = "session_active"
        case messageRole = "message_role"
        case messageContent = "message_content"
        case activityKind = "activity_kind"
        case activityContent = "activity_content"
        case interactionKind = "interaction_kind"
        case projectLabel = "project_label"
        case sessionTitle = "session_title"
        case sessionOpen = "session_open"
        case sessionSurface = "session_surface"
        case terminalApp = "terminal_app"
        case sessionOpenURL = "session_open_url"
    }
}
public struct AgentSessionNavigation: Codable, Hashable, Sendable {
    public var capability: NavigationCapability
    public var sessionOpen: Bool?
    public var surface: String?
    public var terminalApp: String?
    public var openURL: String?
    public var routableSessionID: String?

    public init(
        capability: NavigationCapability = .unavailable,
        sessionOpen: Bool? = nil,
        surface: String? = nil,
        terminalApp: String? = nil,
        openURL: String? = nil,
        routableSessionID: String? = nil
    ) {
        self.capability = capability
        self.sessionOpen = sessionOpen
        self.surface = surface
        self.terminalApp = terminalApp
        self.openURL = openURL
        self.routableSessionID = routableSessionID
    }

    public var explicitlyClosed: Bool { sessionOpen == false }

    enum CodingKeys: String, CodingKey {
        case capability
        case sessionOpen = "session_open"
        case surface
        case terminalApp = "terminal_app"
        case openURL = "open_url"
        case routableSessionID = "routable_session_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capability = try container.decodeIfPresent(
            NavigationCapability.self,
            forKey: .capability
        ) ?? .unavailable
        sessionOpen = try container.decodeIfPresent(Bool.self, forKey: .sessionOpen)
        surface = try container.decodeIfPresent(String.self, forKey: .surface)
        terminalApp = try container.decodeIfPresent(String.self, forKey: .terminalApp)
        openURL = try container.decodeIfPresent(String.self, forKey: .openURL)
        routableSessionID = try container.decodeIfPresent(
            String.self,
            forKey: .routableSessionID
        )
    }
}

public enum AgentOverlaySummaryKind: String, Codable, Hashable, Sendable {
    case start
    case thinking
    case plan
    case command
    case file
    case fileChange = "file_change"
    case tool
    case subagent
    case search
    case network
    case image
    case compaction
    case needsInput = "needs_input"
    case done
    case failed

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        // Accept the pre-atomic-event projection during a managed runtime
        // handoff, but never emit it from the current App.
        if rawValue == "running" {
            self = .start
            return
        }
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported Agent overlay summary kind"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AgentOverlayDisplay: Codable, Hashable, Sendable {
    public var summaryKind: AgentOverlaySummaryKind
    public var navigation: AgentSessionNavigation
    public var stateEntryID: String?

    public init(
        summaryKind: AgentOverlaySummaryKind,
        navigation: AgentSessionNavigation = AgentSessionNavigation(),
        stateEntryID: String? = nil
    ) {
        self.summaryKind = summaryKind
        self.navigation = navigation
        self.stateEntryID = stateEntryID
    }

    enum CodingKeys: String, CodingKey {
        case summaryKind = "summary_kind"
        case navigation
        case stateEntryID = "state_entry_id"
    }
}

public struct AgentEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var source: AgentSource
    public var sessionID: String?
    public var eventType: AgentEventKind
    public var title: String
    public var detail: String?
    public var payloadJSON: AgentEventPayload?
    public var createdAt: String

    public var messageContent: String? {
        payloadJSON?.messageContent?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var sessionNavigation: AgentSessionNavigation {
        AgentSessionNavigation(
            capability: .unavailable,
            sessionOpen: payloadJSON?.sessionOpen,
            surface: payloadJSON?.sessionSurface,
            terminalApp: payloadJSON?.terminalApp,
            openURL: payloadJSON?.sessionOpenURL
        )
    }

    public init(
        id: String,
        source: AgentSource,
        sessionID: String? = nil,
        eventType: AgentEventKind,
        title: String,
        detail: String? = nil,
        payloadJSON: AgentEventPayload? = nil,
        createdAt: String
    ) {
        self.id = id
        self.source = source
        self.sessionID = sessionID
        self.eventType = eventType
        self.title = title
        self.detail = detail
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case sessionID = "session_id"
        case eventType = "event_type"
        case title
        case detail
        case payloadJSON = "payload_json"
        case createdAt = "created_at"
    }
}

public struct ActiveAgentState: Codable, Equatable, Sendable {
    public var state: String
    public var officialStatus: String?
    public var source: AgentSource
    public var sessionID: String?
    public var sessionActive: Bool?
    public var sourceSessionSequence: UInt64
    public var priority: UInt16
    public var leaseSeconds: Int?
    public var expiresAt: String?
    public var sessionActivatedAt: String?
    public var event: AgentEvent
    public var latestMessage: AgentEvent?
    public var latestUserMessage: AgentEvent?
    public var sessionTitle: String?
    public var anonymousSessionAlias: String?
    public var sessionMessage: AgentSessionDisplayMessage?
    public var sessionUserMessage: AgentSessionDisplayMessage?
    public var sessionActivity: AgentSessionActivity?
    public var acknowledgementID: String? = nil
    public var overlayDisplay: AgentOverlayDisplay? = nil

    enum CodingKeys: String, CodingKey {
        case state
        case officialStatus = "official_status"
        case source
        case sessionID = "session_id"
        case sessionActive = "session_active"
        case sourceSessionSequence = "source_session_sequence"
        case priority
        case leaseSeconds = "lease_seconds"
        case expiresAt = "expires_at"
        case sessionActivatedAt = "session_activated_at"
        case event
        case latestMessage = "latest_message"
        case latestUserMessage = "latest_user_message"
        case sessionTitle = "session_title"
        case anonymousSessionAlias = "anonymous_session_alias"
        case sessionMessage = "session_message"
        case sessionUserMessage = "session_user_message"
        case sessionActivity = "session_activity"
        case acknowledgementID = "acknowledgement_id"
        case overlayDisplay = "overlay_display"
    }
}

public struct AgentSessionDisplayMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: String
}

public struct AgentSessionActivity: Codable, Equatable, Sendable {
    public var kind: String
    public var content: String?
}

public struct OverlayVisibility: Codable, Equatable, Sendable {
    public var petVisible: Bool
    public var statusBubbleVisible: Bool

    public init(petVisible: Bool = true, statusBubbleVisible: Bool = true) {
        self.petVisible = petVisible
        self.statusBubbleVisible = statusBubbleVisible
    }

    enum CodingKeys: String, CodingKey {
        case petVisible = "pet_visible"
        case statusBubbleVisible = "status_bubble_visible"
    }
}
