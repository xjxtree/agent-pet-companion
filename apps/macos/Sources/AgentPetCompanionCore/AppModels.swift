import Foundation

public enum NavigationSection: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case library
    case maker
    case configuration
    case connections
    case diagnostics

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .library: "宠物库"
        case .maker: "AI宠物制作"
        case .configuration: "宠物配置"
        case .connections: "Agent 连接"
        case .diagnostics: "服务与诊断"
        }
    }

    public var subtitle: String {
        switch self {
        case .library: "Pet Library"
        case .maker: "AI Pet Maker"
        case .configuration: "Pet Configuration"
        case .connections: "Agent Connections"
        case .diagnostics: "Service & Diagnostics"
        }
    }

    public var systemImage: String {
        switch self {
        case .library: "square.grid.2x2"
        case .maker: "sparkles"
        case .configuration: "slider.horizontal.3"
        case .connections: "cable.connector"
        case .diagnostics: "stethoscope"
        }
    }
}

public enum StylePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case realistic = "写实"
    case semiRealistic = "半写实"
    case modern = "现代"
    case pixel = "像素"
    case anime = "动漫"
    case unspecified = "不指定"

    public var id: String { rawValue }
}

public enum AIPetMakerDefaults {
    public static let descriptionText = ""
    public static let style = StylePreset.semiRealistic
    public static let quality = QualityLevel.standard
    public static let maximumDescriptionCharacters = 8_000
}

public enum QualityLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    case low
    case standard
    case high

    public static let studioCases: [Self] = [.low, .standard]

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .low: "标清"
        case .standard: "标准"
        case .high: "高清"
        }
    }

    public var detail: String {
        let size = renderSize
        switch self {
        case .standard:
            return "\(size.width)×\(size.height) · 推荐"
        default:
            return "\(size.width)×\(size.height)"
        }
    }

    public var renderSize: RenderSize {
        switch self {
        case .low: RenderSize(width: 192, height: 208)
        case .standard: RenderSize(width: 384, height: 416)
        case .high: RenderSize(width: 576, height: 624)
        }
    }

    public var isStudioSupported: Bool { Self.studioCases.contains(self) }
}

public struct RenderSize: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Closed preview/runtime action vocabulary for one V3 pet package.
///
/// The first six cases are Agent-driven semantic states. The final three are
/// local-only overlay interactions and never become Agent session state.
public enum PetAnimationAction: String, CaseIterable, Codable, Hashable, Sendable {
    case idle
    case thinking
    case tool
    case waiting
    case done
    case failed
    case acknowledge
    case dragLeft = "drag_left"
    case dragRight = "drag_right"
}

public enum PetAnimationContract {
    public static let orderedSemanticStateNames = [
        "idle",
        "thinking",
        "tool",
        "waiting",
        "done",
        "failed",
    ]
    public static let orderedInteractionStateNames = [
        "acknowledge",
        "drag_left",
        "drag_right",
    ]
    public static let orderedStateNames =
        orderedSemanticStateNames + orderedInteractionStateNames
    public static let defaultStates: [PetStateTiming] = [
        .init(
            name: "idle",
            framesDir: "assets/frames/idle",
            frameDurationsMS: [260, 220, 240, 260, 380, 640],
            playback: .init(mode: .periodic, cooldownMS: [2_500, 5_000]),
            reducedMotionFrameIndex: 2
        ),
        .init(
            name: "thinking",
            framesDir: "assets/frames/thinking",
            frameDurationsMS: [120, 140, 160, 180],
            playback: .init(mode: .burstThenIdle, entryRepeatCount: 3),
            reducedMotionFrameIndex: 2
        ),
        .init(
            name: "tool",
            framesDir: "assets/frames/tool",
            frameDurationsMS: [150, 150, 170, 330],
            playback: .init(
                mode: .burstThenIdle,
                entryRepeatCount: 3
            ),
            reducedMotionFrameIndex: 2
        ),
        .init(
            name: "waiting",
            framesDir: "assets/frames/waiting",
            frameDurationsMS: [100, 100, 110, 110, 120, 130, 160, 230],
            playback: .init(
                mode: .burstThenSettle,
                entryRepeatCount: 3,
                settleFrameIndex: 7
            ),
            reducedMotionFrameIndex: 4
        ),
        .init(
            name: "done",
            framesDir: "assets/frames/done",
            frameDurationsMS: [120, 140, 160, 230],
            playback: .init(mode: .burstThenIdle, entryRepeatCount: 3),
            reducedMotionFrameIndex: 2
        ),
        .init(
            name: "failed",
            framesDir: "assets/frames/failed",
            frameDurationsMS: [80, 80, 90, 100, 110, 120, 190, 290],
            playback: .init(
                mode: .burstThenSettle,
                entryRepeatCount: 3,
                settleFrameIndex: 7
            ),
            reducedMotionFrameIndex: 2
        ),
        .init(
            name: "acknowledge",
            framesDir: "assets/frames/acknowledge",
            frameDurationsMS: [180, 140, 180, 300],
            playback: .init(mode: .onceThenReturn),
            reducedMotionFrameIndex: 1
        ),
        .init(
            name: "drag_left",
            framesDir: "assets/frames/drag_left",
            frameDurationsMS: [100, 90, 100, 110, 100, 200],
            playback: .init(mode: .loop),
            reducedMotionFrameIndex: 2
        ),
        .init(
            name: "drag_right",
            framesDir: "assets/frames/drag_right",
            frameDurationsMS: [100, 90, 100, 110, 100, 200],
            playback: .init(mode: .loop),
            reducedMotionFrameIndex: 2
        ),
    ]

    public static func hasValidStates(_ states: [PetStateTiming]) -> Bool {
        states.count == orderedStateNames.count
            && Set(states.map(\.name)) == Set(orderedStateNames)
            && states.allSatisfy(\.isValid)
    }
}

public enum PetPlaybackMode: String, Codable, Hashable, Sendable {
    case loop
    case periodic
    case burstThenSettle = "burst_then_settle"
    case burstThenIdle = "burst_then_idle"
    case onceThenReturn = "once_then_return"
}

public struct PlaybackContract: Codable, Hashable, Sendable {
    public static let maximumPeriodicCooldownMS = 86_400_000

    public var mode: PetPlaybackMode
    public var entryRepeatCount: Int?
    public var settleFrameIndex: Int?
    public var cooldownMS: [Int]?

    public init(
        mode: PetPlaybackMode,
        entryRepeatCount: Int? = nil,
        settleFrameIndex: Int? = nil,
        cooldownMS: [Int]? = nil
    ) {
        self.mode = mode
        self.entryRepeatCount = entryRepeatCount
        self.settleFrameIndex = settleFrameIndex
        self.cooldownMS = cooldownMS
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case entryRepeatCount = "entry_repeat_count"
        case settleFrameIndex = "settle_frame_index"
        case cooldownMS = "cooldown_ms"
    }
}

public struct PetStateTiming: Codable, Hashable, Sendable {
    public var name: String
    public var framesDir: String
    public var frameDurationsMS: [Int]
    public var playback: PlaybackContract
    public var reducedMotionFrameIndex: Int

    public init(
        name: String,
        framesDir: String,
        frameDurationsMS: [Int],
        playback: PlaybackContract,
        reducedMotionFrameIndex: Int
    ) {
        self.name = name
        self.framesDir = framesDir
        self.frameDurationsMS = frameDurationsMS
        self.playback = playback
        self.reducedMotionFrameIndex = reducedMotionFrameIndex
    }

    enum CodingKeys: String, CodingKey {
        case name
        case framesDir = "frames_dir"
        case frameDurationsMS = "frame_durations_ms"
        case playback
        case reducedMotionFrameIndex = "reduced_motion_frame_index"
    }

    public var isValid: Bool {
        guard (2...40).contains(frameDurationsMS.count),
              frameDurationsMS.allSatisfy({ (50...2_000).contains($0) }),
              frameDurationsMS.reduce(0, +) <= 5_000,
              frameDurationsMS.indices.contains(reducedMotionFrameIndex)
        else { return false }
        let modeContractValid: Bool
        switch playback.mode {
        case .loop:
            modeContractValid = playback.entryRepeatCount == nil
                && playback.settleFrameIndex == nil
                && playback.cooldownMS == nil
        case .periodic:
            modeContractValid = playback.entryRepeatCount == nil
                && playback.settleFrameIndex == nil
                && playback.cooldownMS?.count == 2
                && playback.cooldownMS.map { $0[0] <= $0[1] } == true
                && playback.cooldownMS.map { cooldowns in
                    cooldowns.allSatisfy {
                        (0...PlaybackContract.maximumPeriodicCooldownMS).contains($0)
                    }
                } == true
        case .burstThenSettle:
            modeContractValid = playback.cooldownMS == nil
                && playback.entryRepeatCount.map { (1...8).contains($0) } == true
                && playback.settleFrameIndex.map(frameDurationsMS.indices.contains) == true
        case .burstThenIdle:
            modeContractValid = playback.cooldownMS == nil
                && playback.settleFrameIndex == nil
                && playback.entryRepeatCount.map { (1...8).contains($0) } == true
        case .onceThenReturn:
            modeContractValid = playback.entryRepeatCount == nil
                && playback.settleFrameIndex == nil
                && playback.cooldownMS == nil
        }
        guard modeContractValid else { return false }
        let expectedMode: PetPlaybackMode? = switch name {
        case "idle": .periodic
        case "thinking", "tool", "done": .burstThenIdle
        case "waiting", "failed": .burstThenSettle
        case "acknowledge": .onceThenReturn
        case "drag_left", "drag_right": .loop
        default: nil
        }
        return playback.mode == expectedMode
    }
}

public enum AgentSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case codex
    case claudeCode = "claude_code"
    case pi
    case opencode

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .pi: "Pi Coding Agent"
        case .opencode: "OpenCode"
        }
    }

    public var shortTitle: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude"
        case .pi: "Pi"
        case .opencode: "OpenCode"
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
        groupSessionsByAgent: Bool = true,
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

public struct PetSummary: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var style: String
    public var quality: QualityLevel
    public var renderSize: RenderSize
    public var petpackPath: String
    public var coverPath: String
    public var origin: PetOrigin
    public var generator: String?
    public var provenance: String?
    public var revisionID: String?
    public var revisionCount: Int
    public var states: [PetStateTiming]
    public var active: Bool
    public var createdAt: String

    public init(
        id: String,
        name: String,
        style: String,
        quality: QualityLevel,
        renderSize: RenderSize,
        petpackPath: String,
        coverPath: String,
        origin: PetOrigin = .externalImport,
        generator: String? = nil,
        provenance: String? = nil,
        revisionID: String? = nil,
        revisionCount: Int = 0,
        states: [PetStateTiming] = PetAnimationContract.defaultStates,
        active: Bool,
        createdAt: String
    ) {
        precondition(PetAnimationContract.hasValidStates(states))
        self.id = id
        self.name = name
        self.style = style
        self.quality = quality
        self.renderSize = renderSize
        self.petpackPath = petpackPath
        self.coverPath = coverPath
        self.origin = origin
        self.generator = generator
        self.provenance = provenance
        self.revisionID = revisionID
        self.revisionCount = max(0, revisionCount)
        self.states = states
        self.active = active
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case style
        case quality
        case renderSize = "render_size"
        case petpackPath = "petpack_path"
        case coverPath = "cover_path"
        case origin
        case generator
        case provenance
        case revisionID = "revision_id"
        case revisionCount = "revision_count"
        case states
        case active
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        style = try container.decode(String.self, forKey: .style)
        quality = try container.decode(QualityLevel.self, forKey: .quality)
        renderSize = try container.decode(RenderSize.self, forKey: .renderSize)
        petpackPath = try container.decode(String.self, forKey: .petpackPath)
        coverPath = try container.decode(String.self, forKey: .coverPath)
        origin = try container.decodeIfPresent(PetOrigin.self, forKey: .origin) ?? .externalImport
        generator = try container.decodeIfPresent(String.self, forKey: .generator)
        provenance = try container.decodeIfPresent(String.self, forKey: .provenance)
        revisionID = try container.decodeIfPresent(String.self, forKey: .revisionID)
        revisionCount = max(0, try container.decodeIfPresent(Int.self, forKey: .revisionCount) ?? 0)
        states = try container.decode([PetStateTiming].self, forKey: .states)
        guard PetAnimationContract.hasValidStates(states) else {
            throw DecodingError.dataCorruptedError(
                forKey: .states,
                in: container,
                debugDescription: "states must contain the nine valid V3 timing contracts"
            )
        }
        active = try container.decode(Bool.self, forKey: .active)
        createdAt = try container.decode(String.self, forKey: .createdAt)
    }

    public func timing(for stateName: String) -> PetStateTiming {
        states.first(where: { $0.name == stateName })
            ?? PetAnimationContract.defaultStates.first(where: { $0.name == stateName })
            ?? PetAnimationContract.defaultStates[0]
    }

    /// Mirrors PetCore's closed bundled identity. A
    /// display name or package-declared marker alone never grants this status.
    public var isBundled: Bool {
        Self.includedCompanionIDSet.contains(id)
            && origin == .verifiedSkillSource
            && generator == "agent-pet-companion.release-inventory"
            && provenance == "apc.bundled-pets.v1"
    }

    /// Stable logical identities reserved for the three companions shipped with
    /// the App. An existing same-ID pet remains user-owned and is never granted
    /// bundled permissions, but it is still a valid first-run choice after an
    /// upgrade because inventory seeding deliberately preserves it.
    public static let includedCompanionIDs = [
        "pet_xingwutuanzi",
        "pet_bytebudcodex",
        "pet_pinklace"
    ]

    public var isIncludedCompanionCandidate: Bool {
        Self.includedCompanionIDSet.contains(id)
    }

    private static let includedCompanionIDSet = Set(includedCompanionIDs)

    public var generationSourceTitle: String {
        if isBundled { return "App 内置" }
        return switch origin {
        case .verifiedSkillSource:
            "已验证 Skill 来源"
        case .generatedByPetcoreJob:
            provenance == "skill-full-source" ? "App 内生成" : "本地动画预览"
        case .externalImport:
            "外部导入"
        }
    }

    public var generationSourceDetail: String {
        if isBundled { return "随 Agent Pet Companion 提供" }
        let claimed = [generator, provenance].compactMap { $0 }.joined(separator: " · ")
        switch origin {
        case .verifiedSkillSource:
            return claimed.isEmpty ? "已通过 App Server Skill source 校验" : "已验证 · \(claimed)"
        case .generatedByPetcoreJob:
            if provenance == "deterministic_preview" || provenance == "local_form" {
                return claimed.isEmpty ? "确定性预览，不代表 AI 图像生成" : "确定性预览 · \(claimed)"
            }
            if provenance == "codex_app_server_brief" {
                return claimed.isEmpty ? "AI brief + 本地预览渲染" : "AI brief + 本地预览 · \(claimed)"
            }
            return claimed.isEmpty ? "由本 App generation job 写入" : "App job · \(claimed)"
        case .externalImport:
            return claimed.isEmpty ? "外部 .petpack 未记录包内声明" : "外部导入 · 包内声明：\(claimed)"
        }
    }
}

public struct PetAssetWarning: Codable, Hashable, Sendable {
    public var petId: String
    public var code: String
    public var fingerprint: String
    public var message: String

    public init(petId: String, code: String, fingerprint: String, message: String) {
        self.petId = petId
        self.code = code
        self.fingerprint = fingerprint
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case petId = "pet_id"
        case code
        case fingerprint
        case message
    }
}

public struct PetAssetRepairOutcome: Codable, Hashable, Sendable {
    public var pet: PetSummary
    public var warning: PetAssetWarning?

    public init(pet: PetSummary, warning: PetAssetWarning?) {
        self.pet = pet
        self.warning = warning
    }
}

public struct PetAssetWarningIndex: Equatable, Sendable {
    private var warningsByPetID: [String: PetAssetWarning]

    public init(_ warnings: [PetAssetWarning] = []) {
        warningsByPetID = Dictionary(warnings.map { ($0.petId, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    public subscript(petID: String) -> PetAssetWarning? {
        warningsByPetID[petID]
    }
}

public enum PetOrigin: String, Codable, Hashable, Sendable {
    case externalImport = "external_import"
    case generatedByPetcoreJob = "generated_by_petcore_job"
    case verifiedSkillSource = "verified_skill_source"
}

/// The single cross-process equality and normalization contract for overlay
/// placement. A 1/256 pt grid is exactly representable by IEEE-754 binary
/// floating point, so canonical coordinates survive Swift/JSON/Rust round
/// trips without an epsilon comparison.
public enum OverlayPlacementCanonicalization {
    public static let gridUnitsPerPoint = 256.0
    public static let quantumPt = 1.0 / gridUnitsPerPoint
    public static let maximumCoordinateMagnitude =
        Double.greatestFiniteMagnitude / gridUnitsPerPoint

    public static func coordinate(_ value: Double) -> Double? {
        guard value.isFinite,
              abs(value) <= maximumCoordinateMagnitude else {
            return nil
        }
        let canonical = (value * gridUnitsPerPoint)
            .rounded(.toNearestOrAwayFromZero) / gridUnitsPerPoint
        guard canonical.isFinite else { return nil }
        return canonical == 0 ? 0 : canonical
    }

    /// Canonicalizes a Core Graphics coordinate while preserving an invalid
    /// input for the caller's existing validation path.
    public static func cgFloatCoordinate(_ value: CGFloat) -> CGFloat {
        guard let canonical = coordinate(Double(value)) else { return value }
        return CGFloat(canonical)
    }

    public static func placement(
        _ placement: OverlayPlacement
    ) -> OverlayPlacement? {
        guard let x = coordinate(placement.x),
              let y = coordinate(placement.y),
              placement.displayWidthPt.isFinite,
              (OverlayPlacement.minimumDisplayWidthPt
                ... OverlayPlacement.maximumDisplayWidthPt)
                .contains(placement.displayWidthPt),
              !placement.displayId.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty else {
            return nil
        }
        var canonical = placement
        canonical.x = x
        canonical.y = y
        return canonical
    }

    public static func areEquivalent(
        _ lhs: OverlayPlacement,
        _ rhs: OverlayPlacement
    ) -> Bool {
        guard let lhs = placement(lhs),
              let rhs = placement(rhs) else {
            return false
        }
        return lhs.x == rhs.x
            && lhs.y == rhs.y
            && lhs.displayWidthPt == rhs.displayWidthPt
            && lhs.displayId == rhs.displayId
    }

    public static func inwardLowerBound(_ value: Double) -> Double? {
        guard value.isFinite,
              abs(value) <= maximumCoordinateMagnitude else {
            return nil
        }
        let canonical = (value * gridUnitsPerPoint)
            .rounded(.up)
            / gridUnitsPerPoint
        return canonical == 0 ? 0 : canonical
    }

    public static func inwardUpperBound(_ value: Double) -> Double? {
        guard value.isFinite,
              abs(value) <= maximumCoordinateMagnitude else {
            return nil
        }
        let canonical = (value * gridUnitsPerPoint)
            .rounded(.down)
            / gridUnitsPerPoint
        return canonical == 0 ? 0 : canonical
    }
}

public struct OverlayPlacement: Codable, Hashable, Sendable {
    public static let minimumDisplayWidthPt = 100.0
    public static let maximumDisplayWidthPt = 300.0
    public static let defaultDisplayWidthPt = 112.0

    public var x: Double
    public var y: Double
    public var displayWidthPt: Double
    public var displayId: String

    public init(
        x: Double = 0,
        y: Double = 0,
        displayWidthPt: Double = defaultDisplayWidthPt,
        displayId: String = "main"
    ) {
        self.x = OverlayPlacementCanonicalization.coordinate(x) ?? x
        self.y = OverlayPlacementCanonicalization.coordinate(y) ?? y
        self.displayWidthPt = Self.clampedDisplayWidth(displayWidthPt)
        self.displayId = displayId
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case x
        case y
        case displayWidthPt = "display_width_pt"
        case displayId = "display_id"
    }

    public init(from decoder: Decoder) throws {
        try OverlayPlacementClosedDecoding.requireOnlyKeys(
            CodingKeys.self,
            from: decoder
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedX = try container.decode(Double.self, forKey: .x)
        let decodedY = try container.decode(Double.self, forKey: .y)
        let decodedDisplayWidthPt = try container.decode(
            Double.self,
            forKey: .displayWidthPt
        )
        let decodedDisplayId = try container.decode(String.self, forKey: .displayId)
        guard decodedX.isFinite,
              decodedY.isFinite,
              decodedDisplayWidthPt.isFinite,
              (Self.minimumDisplayWidthPt ... Self.maximumDisplayWidthPt)
                  .contains(decodedDisplayWidthPt),
              !decodedDisplayId.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty
        else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Overlay placement values are outside the closed contract"
                )
            )
        }
        guard let canonicalX = OverlayPlacementCanonicalization.coordinate(decodedX),
              let canonicalY = OverlayPlacementCanonicalization.coordinate(decodedY) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Overlay placement coordinates cannot be canonicalized"
                )
            )
        }
        x = canonicalX
        y = canonicalY
        displayWidthPt = decodedDisplayWidthPt
        displayId = decodedDisplayId
    }

    public func encode(to encoder: Encoder) throws {
        guard let canonical = OverlayPlacementCanonicalization.placement(self) else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Overlay placement values are outside the closed contract"
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(canonical.x, forKey: .x)
        try container.encode(canonical.y, forKey: .y)
        try container.encode(canonical.displayWidthPt, forKey: .displayWidthPt)
        try container.encode(canonical.displayId, forKey: .displayId)
    }

    private static func clampedDisplayWidth(_ value: Double) -> Double {
        guard value.isFinite else { return defaultDisplayWidthPt }
        return min(maximumDisplayWidthPt, max(minimumDisplayWidthPt, value))
    }
}

private enum OverlayPlacementClosedDecoding {
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
                    debugDescription: "Unknown overlay placement fields: \(unknown.sorted())"
                )
            )
        }
    }
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

public enum ConnectionCheckCode: String, Codable, Hashable, Sendable {
    case agentCLI = "agent_cli"
    case eventCLI = "event_cli"
    case projectDirectory = "project_directory"
    case agentVersion = "agent_version"
    case managedConnector = "managed_connector"
    case claudeHooksPolicy = "claude_hooks_policy"
    case hostRuntime = "host_runtime"
    case hostVerification = "host_verification"
    case eventDelivery = "event_delivery"
    case channelTest = "channel_test"
    case appServer = "app_server"
    case hostServer = "host_server"
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(rawValue: try container.decode(String.self)) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ConnectionCheckRecoveryKind: String, Codable, Hashable, Sendable {
    case chooseProjectDirectory = "choose_project_directory"
    case confirmManagedRepair = "confirm_managed_repair"
    case testChannel = "test_channel"
    case recheck

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Future values must never acquire mutation authority in an older App.
        self = Self(rawValue: try container.decode(String.self)) ?? .recheck
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ConnectionCheckItem: Codable, Hashable, Sendable {
    public var code: ConnectionCheckCode
    public var name: String
    public var status: CheckStatus
    public var detail: String
    public var recoveryAction: ConnectionCheckRecoveryKind?

    public init(
        code: ConnectionCheckCode = .unknown,
        name: String,
        status: CheckStatus,
        detail: String,
        recoveryAction: ConnectionCheckRecoveryKind? = nil
    ) {
        self.code = code
        self.name = name
        self.status = status
        self.detail = detail
        self.recoveryAction = recoveryAction
    }

    public init(
        code: String?,
        name: String,
        status: CheckStatus,
        detail: String,
        recoveryAction: ConnectionCheckRecoveryKind? = nil
    ) {
        self.init(
            code: code.flatMap(ConnectionCheckCode.init(rawValue:)) ?? .unknown,
            name: name,
            status: status,
            detail: detail,
            recoveryAction: recoveryAction
        )
    }

    enum CodingKeys: String, CodingKey {
        case code
        case name
        case status
        case detail
        case recoveryAction = "recovery_action"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(ConnectionCheckCode.self, forKey: .code) ?? .unknown
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(CheckStatus.self, forKey: .status)
        detail = try container.decode(String.self, forKey: .detail)
        recoveryAction = try container.decodeIfPresent(
            ConnectionCheckRecoveryKind.self,
            forKey: .recoveryAction
        )
    }
}

public enum CheckStatus: String, Codable, Hashable, Sendable {
    case ok
    case needsFix = "needs_fix"
    case missing
    case unverified
    case unsupported
    case notRequired = "not_required"

    public var title: String {
        switch self {
        case .ok: "正常"
        case .needsFix: "需修复"
        case .missing: "未检测到"
        case .unverified: "未验证"
        case .unsupported: "暂不支持"
        case .notRequired: "非必需"
        }
    }

    public var isBlocking: Bool {
        self == .needsFix || self == .missing
    }
}

public enum AgentExtensionKind: String, Codable, Hashable, Sendable {
    case connector
    case plugin
    case hostExtension = "extension"
    case package
    case skill
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(rawValue: try container.decode(String.self)) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AgentExtensionOwnership: String, Codable, Hashable, Sendable {
    case appManaged = "app_managed"
    case userManaged = "user_managed"
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(rawValue: try container.decode(String.self)) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AgentManagedComponent: Codable, Hashable, Sendable {
    public var kind: AgentExtensionKind
    public var name: String
    public var ownership: AgentExtensionOwnership
    public var status: CheckStatus
    public var expectedVersion: String?
    public var activeVersion: String?
    public var contentMatches: Bool?

    public init(
        kind: AgentExtensionKind,
        name: String,
        ownership: AgentExtensionOwnership,
        status: CheckStatus,
        expectedVersion: String? = nil,
        activeVersion: String? = nil,
        contentMatches: Bool? = nil
    ) {
        self.kind = kind
        self.name = name
        self.ownership = ownership
        self.status = status
        self.expectedVersion = expectedVersion
        self.activeVersion = activeVersion
        self.contentMatches = contentMatches
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case name
        case ownership
        case status
        case expectedVersion = "expected_version"
        case activeVersion = "active_version"
        case contentMatches = "content_matches"
    }
}

public enum ConnectionCheckMode: String, Codable, Hashable, Sendable {
    case light
    case runtime

    public var title: String {
        switch self {
        case .light: "轻量定位"
        case .runtime: "完整检查"
        }
    }
}

public enum AgentVerificationStatus: String, Codable, Hashable, Sendable {
    case verified
    case actionRequired = "action_required"
    case unverified
    case notRequired = "not_required"

    public var title: String {
        switch self {
        case .verified: "已验证"
        case .actionRequired: "需操作"
        case .unverified: "待验证"
        case .notRequired: "无需验证"
        }
    }

    public var requiresUserAction: Bool {
        self == .actionRequired
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .unverified
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AgentVerification: Codable, Hashable, Sendable {
    public var status: AgentVerificationStatus
    public var title: String
    public var detail: String
    public var lastVerifiedAt: String?
    public var lastEvent: String?
    public var actionDetail: String?
    public var checkedCWD: String?

    public init(
        status: AgentVerificationStatus,
        title: String,
        detail: String,
        lastVerifiedAt: String? = nil,
        lastEvent: String? = nil,
        actionDetail: String? = nil,
        checkedCWD: String? = nil
    ) {
        self.status = status
        self.title = title
        self.detail = detail
        self.lastVerifiedAt = lastVerifiedAt
        self.lastEvent = lastEvent
        self.actionDetail = actionDetail
        self.checkedCWD = checkedCWD
    }

    public static let pending = AgentVerification(
        status: .unverified,
        title: "Agent 侧验证待检查",
        detail: "当前 PetCore 尚未返回 Agent 侧真实触发的验证信息。"
    )

    enum CodingKeys: String, CodingKey {
        case status
        case title
        case detail
        case lastVerifiedAt = "last_verified_at"
        case lastEvent = "last_event"
        case actionDetail = "action_detail"
        case checkedCWD = "checked_cwd"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(AgentVerificationStatus.self, forKey: .status) ?? .unverified
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? Self.pending.title
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? Self.pending.detail
        lastVerifiedAt = try container.decodeIfPresent(String.self, forKey: .lastVerifiedAt)
        lastEvent = try container.decodeIfPresent(String.self, forKey: .lastEvent)
        actionDetail = try container.decodeIfPresent(String.self, forKey: .actionDetail)
        checkedCWD = try container.decodeIfPresent(String.self, forKey: .checkedCWD)
    }
}

public struct AgentConnectorCapabilities: Codable, Hashable, Sendable {
    public var contractVersion: String
    public var auditedEvents: [String]
    public var subscribedEvents: [String]
    public var mappedInformation: [String]
    public var privacyExclusions: [String]
    public var repairableConnectorIssue: Bool?
    public var canRepairManagedConnector: Bool?
    public var managedPathConflict: Bool?
    public var canUninstallManagedConnector: Bool?
    public var managedComponents: [AgentManagedComponent]

    public init(
        contractVersion: String,
        auditedEvents: [String] = [],
        subscribedEvents: [String],
        mappedInformation: [String],
        privacyExclusions: [String],
        repairableConnectorIssue: Bool? = nil,
        canRepairManagedConnector: Bool? = nil,
        managedPathConflict: Bool? = nil,
        canUninstallManagedConnector: Bool? = nil,
        managedComponents: [AgentManagedComponent] = []
    ) {
        self.contractVersion = contractVersion
        self.auditedEvents = auditedEvents
        self.subscribedEvents = subscribedEvents
        self.mappedInformation = mappedInformation
        self.privacyExclusions = privacyExclusions
        self.repairableConnectorIssue = repairableConnectorIssue
        self.canRepairManagedConnector = canRepairManagedConnector
        self.managedPathConflict = managedPathConflict
        self.canUninstallManagedConnector = canUninstallManagedConnector
        self.managedComponents = managedComponents
    }

    public static let empty = AgentConnectorCapabilities(
        contractVersion: "",
        auditedEvents: [],
        subscribedEvents: [],
        mappedInformation: [],
        privacyExclusions: []
    )

    public var hasReportedCapabilities: Bool {
        !contractVersion.isEmpty
            || !auditedEvents.isEmpty
            || !subscribedEvents.isEmpty
            || !mappedInformation.isEmpty
            || !privacyExclusions.isEmpty
            || repairableConnectorIssue != nil
            || canRepairManagedConnector != nil
            || managedPathConflict != nil
            || canUninstallManagedConnector != nil
            || !managedComponents.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case auditedEvents = "audited_events"
        case subscribedEvents = "subscribed_events"
        case mappedInformation = "mapped_information"
        case privacyExclusions = "privacy_exclusions"
        case repairableConnectorIssue = "repairable_connector_issue"
        case canRepairManagedConnector = "can_repair_managed_connector"
        case managedPathConflict = "managed_path_conflict"
        case canUninstallManagedConnector = "can_uninstall_managed_connector"
        case managedComponents = "managed_components"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try container.decodeIfPresent(String.self, forKey: .contractVersion) ?? ""
        auditedEvents = try container.decodeIfPresent([String].self, forKey: .auditedEvents) ?? []
        subscribedEvents = try container.decodeIfPresent([String].self, forKey: .subscribedEvents) ?? []
        mappedInformation = try container.decodeIfPresent([String].self, forKey: .mappedInformation) ?? []
        privacyExclusions = try container.decodeIfPresent([String].self, forKey: .privacyExclusions) ?? []
        repairableConnectorIssue = try container.decodeIfPresent(Bool.self, forKey: .repairableConnectorIssue)
        canRepairManagedConnector = try container.decodeIfPresent(
            Bool.self,
            forKey: .canRepairManagedConnector
        )
        managedPathConflict = try container.decodeIfPresent(Bool.self, forKey: .managedPathConflict)
        canUninstallManagedConnector = try container.decodeIfPresent(
            Bool.self,
            forKey: .canUninstallManagedConnector
        )
        managedComponents = try container.decodeIfPresent(
            [AgentManagedComponent].self,
            forKey: .managedComponents
        ) ?? []
    }
}

public struct AgentConnectionStatus: Codable, Identifiable, Hashable, Sendable {
    public var id: AgentSource { source }
    public var source: AgentSource
    public var items: [ConnectionCheckItem]
    public var installPaths: [String]
    public var connectorInstalled: Bool?
    public var checkMode: ConnectionCheckMode
    public var checkedAt: String?
    public var verification: AgentVerification
    public var capabilities: AgentConnectorCapabilities

    public init(
        source: AgentSource,
        items: [ConnectionCheckItem],
        installPaths: [String],
        connectorInstalled: Bool? = nil,
        checkMode: ConnectionCheckMode = .runtime,
        checkedAt: String? = nil,
        verification: AgentVerification = .pending,
        capabilities: AgentConnectorCapabilities = .empty
    ) {
        self.source = source
        self.items = items
        self.installPaths = installPaths
        self.connectorInstalled = connectorInstalled
        self.checkMode = checkMode
        self.checkedAt = checkedAt
        self.verification = verification
        self.capabilities = capabilities
    }

    enum CodingKeys: String, CodingKey {
        case source
        case items
        case installPaths = "install_paths"
        case connectorInstalled = "connector_installed"
        case checkMode = "check_mode"
        case checkedAt = "checked_at"
        case verification
        case capabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(AgentSource.self, forKey: .source)
        items = try container.decode([ConnectionCheckItem].self, forKey: .items)
        installPaths = try container.decode([String].self, forKey: .installPaths)
        connectorInstalled = try container.decodeIfPresent(Bool.self, forKey: .connectorInstalled)
        checkMode = try container.decodeIfPresent(ConnectionCheckMode.self, forKey: .checkMode) ?? .runtime
        checkedAt = try container.decodeIfPresent(String.self, forKey: .checkedAt)
        verification = try container.decodeIfPresent(AgentVerification.self, forKey: .verification) ?? .pending
        capabilities = try container.decodeIfPresent(AgentConnectorCapabilities.self, forKey: .capabilities) ?? .empty
    }

    public var hasInstalledConnectorArtifacts: Bool {
        connectorInstalled ?? false
    }

    public var hasRepairableConnectorIssue: Bool {
        capabilities.repairableConnectorIssue == true
            && capabilities.managedPathConflict == false
    }

    public var hasManagedPathConflict: Bool {
        capabilities.managedPathConflict == true
    }

    public var canRepairManagedConnector: Bool {
        capabilities.canRepairManagedConnector == true
            && capabilities.managedPathConflict == false
    }

    public var canUninstallManagedConnector: Bool {
        capabilities.canUninstallManagedConnector == true
            && capabilities.managedPathConflict == false
    }


    public var blockingItems: [ConnectionCheckItem] {
        items.filter { $0.status.isBlocking }
    }

    public var unverifiedItems: [ConnectionCheckItem] {
        items.filter { $0.status == .unverified }
    }

    public var unsupportedItems: [ConnectionCheckItem] {
        items.filter { $0.status == .unsupported }
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
