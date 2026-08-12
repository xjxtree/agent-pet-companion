import Foundation

public enum AppearanceTheme: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case dark
    case light

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "跟随系统"
        case .dark: "黑色主题"
        case .light: "白色主题"
        }
    }
}

public enum InterfaceLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case english
    case simplifiedChinese = "simplified_chinese"

    public var id: String { rawValue }
}

public enum SessionGroupDisplay: String, CaseIterable, Identifiable, Codable, Sendable {
    case stacked
    case expanded

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .stacked: "堆叠"
        case .expanded: "展开"
        }
    }
}

/// Bubble text size as a closed set of tiers rather than a free slider. One
/// multiplier scales every bubble text role, so the authored size relationships
/// between title, detail, and badge copy stay exactly as designed.
public enum BubbleFontScale: String, CaseIterable, Identifiable, Codable, Sendable {
    case standard
    case large

    public var id: String { rawValue }

    public var multiplier: Double {
        switch self {
        case .standard: 1
        case .large: 1.15
        }
    }

    public var title: String {
        switch self {
        case .standard: "标准"
        case .large: "更大"
        }
    }
}

public struct BehaviorSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var statusBubble: Bool
    public var interfaceLanguage: InterfaceLanguage
    public var appearanceTheme: AppearanceTheme
    public var bubbleFontScale: BubbleFontScale
    public var clickMenu: Bool
    /// Retained on the wire for compatibility. Transparent-area passthrough is
    /// a product invariant and is therefore always enabled.
    public let mousePassthrough: Bool
    public var autoHide: Bool
    public var sessionMessageTimeoutMinutes: Int
    public var groupSessionsByAgent: Bool
    public var sessionGroupDisplay: SessionGroupDisplay
    public var sources: [AgentSource: Bool]
    public var events: [AgentEventKind: Bool]

    public init(
        enabled: Bool = true,
        statusBubble: Bool = true,
        interfaceLanguage: InterfaceLanguage = .system,
        appearanceTheme: AppearanceTheme = .system,
        bubbleFontScale: BubbleFontScale = .standard,
        clickMenu: Bool = true,
        autoHide: Bool = false,
        sessionMessageTimeoutMinutes: Int = 15,
        groupSessionsByAgent: Bool = false,
        sessionGroupDisplay: SessionGroupDisplay = .stacked,
        sources: [AgentSource: Bool] = Dictionary(uniqueKeysWithValues: AgentSource.allCases.map { ($0, true) }),
        events: [AgentEventKind: Bool] = Dictionary(uniqueKeysWithValues: AgentEventKind.allCases.map { ($0, true) })
    ) {
        self.enabled = enabled
        self.statusBubble = statusBubble
        self.interfaceLanguage = interfaceLanguage
        self.appearanceTheme = appearanceTheme
        self.bubbleFontScale = bubbleFontScale
        self.clickMenu = clickMenu
        self.mousePassthrough = true
        self.autoHide = autoHide
        self.sessionMessageTimeoutMinutes = sessionMessageTimeoutMinutes
        self.groupSessionsByAgent = groupSessionsByAgent
        self.sessionGroupDisplay = sessionGroupDisplay
        self.sources = sources
        self.events = events
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case statusBubble = "status_bubble"
        case interfaceLanguage = "interface_language"
        case appearanceTheme = "appearance_theme"
        case bubbleFontScale = "bubble_font_scale"
        case clickMenu = "click_menu"
        case mousePassthrough = "mouse_passthrough"
        case autoHide = "auto_hide"
        case sessionMessageTimeoutMinutes = "session_message_timeout_minutes"
        case groupSessionsByAgent = "group_sessions_by_agent"
        case sessionGroupDisplay = "session_group_display"
        case sources
        case events
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BehaviorSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        statusBubble = try container.decodeIfPresent(Bool.self, forKey: .statusBubble) ?? defaults.statusBubble
        interfaceLanguage = try container.decodeIfPresent(
            InterfaceLanguage.self,
            forKey: .interfaceLanguage
        ) ?? defaults.interfaceLanguage
        appearanceTheme = try container.decodeIfPresent(AppearanceTheme.self, forKey: .appearanceTheme)
            ?? defaults.appearanceTheme
        bubbleFontScale = try container.decodeIfPresent(
            BubbleFontScale.self,
            forKey: .bubbleFontScale
        ) ?? defaults.bubbleFontScale
        clickMenu = try container.decodeIfPresent(Bool.self, forKey: .clickMenu) ?? defaults.clickMenu
        // Canonicalize legacy persisted `false` values during decode. The key
        // remains present so older App/PetCore versions can still read state.
        mousePassthrough = true
        autoHide = try container.decodeIfPresent(Bool.self, forKey: .autoHide) ?? defaults.autoHide
        sessionMessageTimeoutMinutes = try container.decodeIfPresent(
            Int.self,
            forKey: .sessionMessageTimeoutMinutes
        ) ?? defaults.sessionMessageTimeoutMinutes
        groupSessionsByAgent = try container.decodeIfPresent(
            Bool.self,
            forKey: .groupSessionsByAgent
        ) ?? defaults.groupSessionsByAgent
        sessionGroupDisplay = try container.decodeIfPresent(
            SessionGroupDisplay.self,
            forKey: .sessionGroupDisplay
        ) ?? defaults.sessionGroupDisplay
        let rawSources = try container.decodeIfPresent([String: Bool].self, forKey: .sources) ?? [:]
        sources = Dictionary(uniqueKeysWithValues: AgentSource.allCases.map { source in
            (source, rawSources[source.rawValue] ?? defaults.sources[source, default: true])
        })

        let rawEvents = try container.decodeIfPresent([String: Bool].self, forKey: .events) ?? [:]
        events = Dictionary(uniqueKeysWithValues: AgentEventKind.allCases.map { event in
            (event, rawEvents[event.rawValue] ?? defaults.events[event, default: true])
        })
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(statusBubble, forKey: .statusBubble)
        try container.encode(interfaceLanguage, forKey: .interfaceLanguage)
        try container.encode(appearanceTheme, forKey: .appearanceTheme)
        try container.encode(bubbleFontScale, forKey: .bubbleFontScale)
        try container.encode(clickMenu, forKey: .clickMenu)
        try container.encode(true, forKey: .mousePassthrough)
        try container.encode(autoHide, forKey: .autoHide)
        try container.encode(sessionMessageTimeoutMinutes, forKey: .sessionMessageTimeoutMinutes)
        try container.encode(groupSessionsByAgent, forKey: .groupSessionsByAgent)
        try container.encode(sessionGroupDisplay, forKey: .sessionGroupDisplay)
        try container.encode(
            Dictionary(uniqueKeysWithValues: sources.map { ($0.key.rawValue, $0.value) }),
            forKey: .sources
        )
        try container.encode(
            Dictionary(uniqueKeysWithValues: events.map { ($0.key.rawValue, $0.value) }),
            forKey: .events
        )
    }

    public func showsStatusBubble(hasActiveEvent: Bool, dismissed: Bool) -> Bool {
        enabled && statusBubble && !dismissed && (!autoHide || hasActiveEvent)
    }

}

public struct BehaviorSettingsPatch: Codable, Equatable, Sendable {
    public var enabled: Bool?
    public var statusBubble: Bool?
    public var interfaceLanguage: InterfaceLanguage?
    public var appearanceTheme: AppearanceTheme?
    public var bubbleFontScale: BubbleFontScale?
    public var clickMenu: Bool?
    public var autoHide: Bool?
    public var sessionMessageTimeoutMinutes: Int?
    public var groupSessionsByAgent: Bool?
    public var sessionGroupDisplay: SessionGroupDisplay?
    public var sources: [AgentSource: Bool]?
    public var events: [AgentEventKind: Bool]?

    public init(from previous: BehaviorSettings, to next: BehaviorSettings) {
        enabled = previous.enabled == next.enabled ? nil : next.enabled
        statusBubble = previous.statusBubble == next.statusBubble ? nil : next.statusBubble
        interfaceLanguage = previous.interfaceLanguage == next.interfaceLanguage
            ? nil
            : next.interfaceLanguage
        appearanceTheme = previous.appearanceTheme == next.appearanceTheme ? nil : next.appearanceTheme
        bubbleFontScale = previous.bubbleFontScale == next.bubbleFontScale
            ? nil
            : next.bubbleFontScale
        clickMenu = previous.clickMenu == next.clickMenu ? nil : next.clickMenu
        autoHide = previous.autoHide == next.autoHide ? nil : next.autoHide
        sessionMessageTimeoutMinutes = previous.sessionMessageTimeoutMinutes == next.sessionMessageTimeoutMinutes
            ? nil
            : next.sessionMessageTimeoutMinutes
        groupSessionsByAgent = previous.groupSessionsByAgent == next.groupSessionsByAgent
            ? nil
            : next.groupSessionsByAgent
        sessionGroupDisplay = previous.sessionGroupDisplay == next.sessionGroupDisplay
            ? nil
            : next.sessionGroupDisplay
        let changedSources = next.sources.filter { previous.sources[$0.key] != $0.value }
        sources = changedSources.isEmpty ? nil : changedSources
        let changedEvents = next.events.filter { previous.events[$0.key] != $0.value }
        events = changedEvents.isEmpty ? nil : changedEvents
    }

    public var isEmpty: Bool {
        enabled == nil
            && statusBubble == nil
            && interfaceLanguage == nil
            && appearanceTheme == nil
            && bubbleFontScale == nil
            && clickMenu == nil
            && autoHide == nil
            && sessionMessageTimeoutMinutes == nil
            && groupSessionsByAgent == nil
            && sessionGroupDisplay == nil
            && sources?.isEmpty != false
            && events?.isEmpty != false
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case statusBubble = "status_bubble"
        case interfaceLanguage = "interface_language"
        case appearanceTheme = "appearance_theme"
        case bubbleFontScale = "bubble_font_scale"
        case clickMenu = "click_menu"
        case autoHide = "auto_hide"
        case sessionMessageTimeoutMinutes = "session_message_timeout_minutes"
        case groupSessionsByAgent = "group_sessions_by_agent"
        case sessionGroupDisplay = "session_group_display"
        case sources
        case events
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        statusBubble = try container.decodeIfPresent(Bool.self, forKey: .statusBubble)
        interfaceLanguage = try container.decodeIfPresent(
            InterfaceLanguage.self,
            forKey: .interfaceLanguage
        )
        appearanceTheme = try container.decodeIfPresent(AppearanceTheme.self, forKey: .appearanceTheme)
        bubbleFontScale = try container.decodeIfPresent(
            BubbleFontScale.self,
            forKey: .bubbleFontScale
        )
        clickMenu = try container.decodeIfPresent(Bool.self, forKey: .clickMenu)
        autoHide = try container.decodeIfPresent(Bool.self, forKey: .autoHide)
        sessionMessageTimeoutMinutes = try container.decodeIfPresent(
            Int.self,
            forKey: .sessionMessageTimeoutMinutes
        )
        groupSessionsByAgent = try container.decodeIfPresent(
            Bool.self,
            forKey: .groupSessionsByAgent
        )
        sessionGroupDisplay = try container.decodeIfPresent(
            SessionGroupDisplay.self,
            forKey: .sessionGroupDisplay
        )
        let rawSources = try container.decodeIfPresent([String: Bool].self, forKey: .sources)
        sources = rawSources.map { values in
            Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
                AgentSource(rawValue: key).map { ($0, value) }
            })
        }
        let rawEvents = try container.decodeIfPresent([String: Bool].self, forKey: .events)
        events = rawEvents.map { values in
            Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
                AgentEventKind(rawValue: key).map { ($0, value) }
            })
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encodeIfPresent(statusBubble, forKey: .statusBubble)
        try container.encodeIfPresent(interfaceLanguage, forKey: .interfaceLanguage)
        try container.encodeIfPresent(appearanceTheme, forKey: .appearanceTheme)
        try container.encodeIfPresent(bubbleFontScale, forKey: .bubbleFontScale)
        try container.encodeIfPresent(clickMenu, forKey: .clickMenu)
        try container.encodeIfPresent(autoHide, forKey: .autoHide)
        try container.encodeIfPresent(
            sessionMessageTimeoutMinutes,
            forKey: .sessionMessageTimeoutMinutes
        )
        try container.encodeIfPresent(groupSessionsByAgent, forKey: .groupSessionsByAgent)
        try container.encodeIfPresent(sessionGroupDisplay, forKey: .sessionGroupDisplay)
        if let sources {
            try container.encode(
                Dictionary(uniqueKeysWithValues: sources.map { ($0.key.rawValue, $0.value) }),
                forKey: .sources
            )
        }
        if let events {
            try container.encode(
                Dictionary(uniqueKeysWithValues: events.map { ($0.key.rawValue, $0.value) }),
                forKey: .events
            )
        }
    }
}

public struct VersionedBehaviorSettings: Codable, Equatable, Sendable {
    public var behavior: BehaviorSettings
    public var revision: String
}
