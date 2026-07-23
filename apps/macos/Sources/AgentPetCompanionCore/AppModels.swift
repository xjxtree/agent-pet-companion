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
    public static let maximumDescriptionCharacters = 8_000
}

public enum QualityLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    case standard
    case high
    case ultra
    case original

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: "标清"
        case .high: "高清"
        case .ultra: "超清"
        case .original: "原画"
        }
    }

    public var detail: String {
        let size = renderSize
        switch self {
        case .high:
            return "\(size.width)×\(size.height) · 推荐"
        default:
            return "\(size.width)×\(size.height)"
        }
    }

    public var renderSize: RenderSize {
        switch self {
        case .standard: RenderSize(width: 192, height: 208)
        case .high: RenderSize(width: 384, height: 416)
        case .ultra: RenderSize(width: 768, height: 832)
        case .original: RenderSize(width: 1536, height: 1664)
        }
    }
}

public struct RenderSize: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum FpsProfile: String, CaseIterable, Identifiable, Codable, Sendable {
    case standard
    case smooth

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: "标准动效"
        case .smooth: "流畅动效"
        }
    }

    public var fps: Int {
        switch self {
        case .standard: 10
        case .smooth: 20
        }
    }
}

public enum PetAnimationContract {
    public static let defaultNativeFPS = 10
    public static let supportedNativeFPS: Set<Int> = [10, 20]
    public static let supportedDurationsMS: Set<Int> = [1_000, 2_000]
    public static let orderedStateNames = [
        "idle",
        "start",
        "tool",
        "waiting",
        "review",
        "done",
        "failed",
    ]
    public static let defaultStateDurationsMS: [String: Int] = [
        "idle": 2_000,
        "start": 1_000,
        "tool": 2_000,
        "waiting": 2_000,
        "review": 2_000,
        "done": 1_000,
        "failed": 2_000,
    ]

    public static func loops(stateName: String) -> Bool {
        stateName != "start" && stateName != "done"
    }

    public static func hasValidStateDurations(_ durations: [String: Int]) -> Bool {
        durations.keys.count == orderedStateNames.count
            && Set(durations.keys) == Set(orderedStateNames)
            && durations.values.allSatisfy(supportedDurationsMS.contains)
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
    case tool
    case waiting
    case review
    case done
    case failed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .start: "开始处理"
        case .tool: "执行工具"
        case .waiting: "等待确认"
        case .review: "待查看"
        case .done: "完成"
        case .failed: "失败"
        }
    }

    public var petState: String { rawValue }
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

public struct BehaviorSettings: Codable, Equatable, Sendable {
    public static let defaultBubbleTransparency = 0.55

    public var enabled: Bool
    public var statusBubble: Bool
    public var appearanceTheme: AppearanceTheme
    public var bubbleTransparency: Double
    public var clickMenu: Bool
    public var mousePassthrough: Bool
    public var autoHide: Bool
    public var sessionMessageTimeoutMinutes: Int
    public var sessionGroupDisplay: SessionGroupDisplay
    public var fpsProfile: FpsProfile
    public var sources: [AgentSource: Bool]
    public var events: [AgentEventKind: Bool]

    public init(
        enabled: Bool = true,
        statusBubble: Bool = true,
        appearanceTheme: AppearanceTheme = .system,
        bubbleTransparency: Double = BehaviorSettings.defaultBubbleTransparency,
        clickMenu: Bool = true,
        mousePassthrough: Bool = true,
        autoHide: Bool = false,
        sessionMessageTimeoutMinutes: Int = 15,
        sessionGroupDisplay: SessionGroupDisplay = .stacked,
        fpsProfile: FpsProfile = .standard,
        sources: [AgentSource: Bool] = Dictionary(uniqueKeysWithValues: AgentSource.allCases.map { ($0, true) }),
        events: [AgentEventKind: Bool] = Dictionary(uniqueKeysWithValues: AgentEventKind.allCases.map { ($0, true) })
    ) {
        self.enabled = enabled
        self.statusBubble = statusBubble
        self.appearanceTheme = appearanceTheme
        self.bubbleTransparency = Self.clampedBubbleTransparency(bubbleTransparency)
        self.clickMenu = clickMenu
        self.mousePassthrough = mousePassthrough
        self.autoHide = autoHide
        self.sessionMessageTimeoutMinutes = sessionMessageTimeoutMinutes
        self.sessionGroupDisplay = sessionGroupDisplay
        self.fpsProfile = fpsProfile
        self.sources = sources
        self.events = events
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case statusBubble = "status_bubble"
        case appearanceTheme = "appearance_theme"
        case bubbleTransparency = "bubble_transparency"
        case clickMenu = "click_menu"
        case mousePassthrough = "mouse_passthrough"
        case autoHide = "auto_hide"
        case sessionMessageTimeoutMinutes = "session_message_timeout_minutes"
        case sessionGroupDisplay = "session_group_display"
        case fpsProfile = "fps_profile"
        case sources
        case events
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BehaviorSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        statusBubble = try container.decodeIfPresent(Bool.self, forKey: .statusBubble) ?? defaults.statusBubble
        appearanceTheme = try container.decodeIfPresent(AppearanceTheme.self, forKey: .appearanceTheme)
            ?? defaults.appearanceTheme
        bubbleTransparency = Self.clampedBubbleTransparency(
            try container.decodeIfPresent(Double.self, forKey: .bubbleTransparency)
                ?? defaults.bubbleTransparency
        )
        clickMenu = try container.decodeIfPresent(Bool.self, forKey: .clickMenu) ?? defaults.clickMenu
        mousePassthrough = try container.decodeIfPresent(Bool.self, forKey: .mousePassthrough) ?? defaults.mousePassthrough
        autoHide = try container.decodeIfPresent(Bool.self, forKey: .autoHide) ?? defaults.autoHide
        sessionMessageTimeoutMinutes = try container.decodeIfPresent(
            Int.self,
            forKey: .sessionMessageTimeoutMinutes
        ) ?? defaults.sessionMessageTimeoutMinutes
        sessionGroupDisplay = try container.decodeIfPresent(
            SessionGroupDisplay.self,
            forKey: .sessionGroupDisplay
        ) ?? defaults.sessionGroupDisplay
        fpsProfile = try container.decodeIfPresent(FpsProfile.self, forKey: .fpsProfile) ?? defaults.fpsProfile

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
        try container.encode(appearanceTheme, forKey: .appearanceTheme)
        try container.encode(bubbleTransparency, forKey: .bubbleTransparency)
        try container.encode(clickMenu, forKey: .clickMenu)
        try container.encode(mousePassthrough, forKey: .mousePassthrough)
        try container.encode(autoHide, forKey: .autoHide)
        try container.encode(sessionMessageTimeoutMinutes, forKey: .sessionMessageTimeoutMinutes)
        try container.encode(sessionGroupDisplay, forKey: .sessionGroupDisplay)
        try container.encode(fpsProfile, forKey: .fpsProfile)
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

    public static func clampedBubbleTransparency(_ value: Double) -> Double {
        min(max(value.isFinite ? value : defaultBubbleTransparency, 0), 1)
    }
}

public struct BehaviorSettingsPatch: Codable, Equatable, Sendable {
    public var enabled: Bool?
    public var statusBubble: Bool?
    public var appearanceTheme: AppearanceTheme?
    public var bubbleTransparency: Double?
    public var clickMenu: Bool?
    public var mousePassthrough: Bool?
    public var autoHide: Bool?
    public var sessionMessageTimeoutMinutes: Int?
    public var sessionGroupDisplay: SessionGroupDisplay?
    public var fpsProfile: FpsProfile?
    public var sources: [AgentSource: Bool]?
    public var events: [AgentEventKind: Bool]?

    public init(from previous: BehaviorSettings, to next: BehaviorSettings) {
        enabled = previous.enabled == next.enabled ? nil : next.enabled
        statusBubble = previous.statusBubble == next.statusBubble ? nil : next.statusBubble
        appearanceTheme = previous.appearanceTheme == next.appearanceTheme ? nil : next.appearanceTheme
        bubbleTransparency = previous.bubbleTransparency == next.bubbleTransparency
            ? nil
            : next.bubbleTransparency
        clickMenu = previous.clickMenu == next.clickMenu ? nil : next.clickMenu
        mousePassthrough = previous.mousePassthrough == next.mousePassthrough
            ? nil
            : next.mousePassthrough
        autoHide = previous.autoHide == next.autoHide ? nil : next.autoHide
        sessionMessageTimeoutMinutes = previous.sessionMessageTimeoutMinutes == next.sessionMessageTimeoutMinutes
            ? nil
            : next.sessionMessageTimeoutMinutes
        sessionGroupDisplay = previous.sessionGroupDisplay == next.sessionGroupDisplay
            ? nil
            : next.sessionGroupDisplay
        fpsProfile = previous.fpsProfile == next.fpsProfile ? nil : next.fpsProfile
        let changedSources = next.sources.filter { previous.sources[$0.key] != $0.value }
        sources = changedSources.isEmpty ? nil : changedSources
        let changedEvents = next.events.filter { previous.events[$0.key] != $0.value }
        events = changedEvents.isEmpty ? nil : changedEvents
    }

    public var isEmpty: Bool {
        enabled == nil
            && statusBubble == nil
            && appearanceTheme == nil
            && bubbleTransparency == nil
            && clickMenu == nil
            && mousePassthrough == nil
            && autoHide == nil
            && sessionMessageTimeoutMinutes == nil
            && sessionGroupDisplay == nil
            && fpsProfile == nil
            && sources?.isEmpty != false
            && events?.isEmpty != false
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case statusBubble = "status_bubble"
        case appearanceTheme = "appearance_theme"
        case bubbleTransparency = "bubble_transparency"
        case clickMenu = "click_menu"
        case mousePassthrough = "mouse_passthrough"
        case autoHide = "auto_hide"
        case sessionMessageTimeoutMinutes = "session_message_timeout_minutes"
        case sessionGroupDisplay = "session_group_display"
        case fpsProfile = "fps_profile"
        case sources
        case events
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        statusBubble = try container.decodeIfPresent(Bool.self, forKey: .statusBubble)
        appearanceTheme = try container.decodeIfPresent(AppearanceTheme.self, forKey: .appearanceTheme)
        bubbleTransparency = try container.decodeIfPresent(Double.self, forKey: .bubbleTransparency)
        clickMenu = try container.decodeIfPresent(Bool.self, forKey: .clickMenu)
        mousePassthrough = try container.decodeIfPresent(Bool.self, forKey: .mousePassthrough)
        autoHide = try container.decodeIfPresent(Bool.self, forKey: .autoHide)
        sessionMessageTimeoutMinutes = try container.decodeIfPresent(
            Int.self,
            forKey: .sessionMessageTimeoutMinutes
        )
        sessionGroupDisplay = try container.decodeIfPresent(
            SessionGroupDisplay.self,
            forKey: .sessionGroupDisplay
        )
        fpsProfile = try container.decodeIfPresent(FpsProfile.self, forKey: .fpsProfile)
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
        try container.encodeIfPresent(appearanceTheme, forKey: .appearanceTheme)
        try container.encodeIfPresent(bubbleTransparency, forKey: .bubbleTransparency)
        try container.encodeIfPresent(clickMenu, forKey: .clickMenu)
        try container.encodeIfPresent(mousePassthrough, forKey: .mousePassthrough)
        try container.encodeIfPresent(autoHide, forKey: .autoHide)
        try container.encodeIfPresent(
            sessionMessageTimeoutMinutes,
            forKey: .sessionMessageTimeoutMinutes
        )
        try container.encodeIfPresent(sessionGroupDisplay, forKey: .sessionGroupDisplay)
        try container.encodeIfPresent(fpsProfile, forKey: .fpsProfile)
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
    public var nativeFPS: Int
    public var stateDurationsMS: [String: Int]
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
        nativeFPS: Int = PetAnimationContract.defaultNativeFPS,
        stateDurationsMS: [String: Int] = PetAnimationContract.defaultStateDurationsMS,
        active: Bool,
        createdAt: String
    ) {
        precondition(PetAnimationContract.supportedNativeFPS.contains(nativeFPS))
        precondition(PetAnimationContract.hasValidStateDurations(stateDurationsMS))
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
        self.nativeFPS = nativeFPS
        self.stateDurationsMS = stateDurationsMS
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
        case nativeFPS = "native_fps"
        case stateDurationsMS = "state_durations_ms"
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
        nativeFPS = try container.decode(Int.self, forKey: .nativeFPS)
        guard PetAnimationContract.supportedNativeFPS.contains(nativeFPS) else {
            throw DecodingError.dataCorruptedError(
                forKey: .nativeFPS,
                in: container,
                debugDescription: "native_fps must be 10 or 20"
            )
        }
        stateDurationsMS = try container.decode([String: Int].self, forKey: .stateDurationsMS)
        guard PetAnimationContract.hasValidStateDurations(stateDurationsMS) else {
            throw DecodingError.dataCorruptedError(
                forKey: .stateDurationsMS,
                in: container,
                debugDescription: "state_durations_ms must contain exactly the seven states at 1000 or 2000 ms"
            )
        }
        active = try container.decode(Bool.self, forKey: .active)
        createdAt = try container.decode(String.self, forKey: .createdAt)
    }

    public var supportedFPSProfiles: [FpsProfile] {
        nativeFPS == FpsProfile.smooth.fps ? [.standard, .smooth] : [.standard]
    }

    public func effectiveFPSProfile(_ requested: FpsProfile) -> FpsProfile {
        supportedFPSProfiles.contains(requested) ? requested : .standard
    }

    public func durationMS(for stateName: String) -> Int {
        stateDurationsMS[stateName]
            ?? PetAnimationContract.defaultStateDurationsMS[stateName]
            ?? 1_000
    }

    /// Mirrors PetCore's schema-5-compatible, closed bundled identity. A
    /// display name or package-declared marker alone never grants this status.
    public var isBundled: Bool {
        Self.bundledPetIDs.contains(id)
            && origin == .verifiedSkillSource
            && generator == "agent-pet-companion.release-inventory"
            && provenance == "apc.bundled-pets.v1"
    }

    private static let bundledPetIDs: Set<String> = [
        "pet_xingwutuanzi",
        "pet_bytebudcodex"
    ]

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

public struct OverlayPlacement: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var scale: Double
    public var displayId: String

    public init(x: Double = 0, y: Double = 0, scale: Double = 0.72, displayId: String = "main") {
        self.x = x
        self.y = y
        self.scale = scale
        self.displayId = displayId
    }

    enum CodingKeys: String, CodingKey {
        case x
        case y
        case scale
        case displayId = "display_id"
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
    public var sessionOpen: Bool?
    public var surface: String?
    public var terminalApp: String?
    public var openURL: String?
    public var routableSessionID: String?

    public init(
        sessionOpen: Bool? = nil,
        surface: String? = nil,
        terminalApp: String? = nil,
        openURL: String? = nil,
        routableSessionID: String? = nil
    ) {
        self.sessionOpen = sessionOpen
        self.surface = surface
        self.terminalApp = terminalApp
        self.openURL = openURL
        self.routableSessionID = routableSessionID
    }

    public var explicitlyClosed: Bool { sessionOpen == false }

    enum CodingKeys: String, CodingKey {
        case sessionOpen = "session_open"
        case surface
        case terminalApp = "terminal_app"
        case openURL = "open_url"
        case routableSessionID = "routable_session_id"
    }
}

public enum AgentOverlaySummaryKind: String, Codable, Hashable, Sendable {
    case running
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
    case review
    case done
    case failed
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
    public var sessionMessage: AgentSessionDisplayMessage?
    public var sessionUserMessage: AgentSessionDisplayMessage?
    public var sessionActivity: AgentSessionActivity?
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
        case sessionMessage = "session_message"
        case sessionUserMessage = "session_user_message"
        case sessionActivity = "session_activity"
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

public struct GenerationMessage: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var role: String
    public var content: String
    public var progress: Double
    public var createdAt: String
    public var kind: String?

    public init(id: String = UUID().uuidString, role: String, content: String, progress: Double, createdAt: String, kind: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.progress = progress
        self.createdAt = createdAt
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case progress
        case createdAt = "created_at"
        case kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        progress = try container.decode(Double.self, forKey: .progress)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
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

    public static func activeStepIndex(messages: [GenerationMessage], progress: Double) -> Int {
        if succeeded(messages) {
            return 3
        }
        if needsUserInput(messages) {
            return 1
        }
        if terminalUnsuccessful(messages) {
            return 2
        }

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
    public var managedPathConflict: Bool?
    public var canUninstallManagedConnector: Bool?

    public init(
        contractVersion: String,
        auditedEvents: [String] = [],
        subscribedEvents: [String],
        mappedInformation: [String],
        privacyExclusions: [String],
        repairableConnectorIssue: Bool? = nil,
        managedPathConflict: Bool? = nil,
        canUninstallManagedConnector: Bool? = nil
    ) {
        self.contractVersion = contractVersion
        self.auditedEvents = auditedEvents
        self.subscribedEvents = subscribedEvents
        self.mappedInformation = mappedInformation
        self.privacyExclusions = privacyExclusions
        self.repairableConnectorIssue = repairableConnectorIssue
        self.managedPathConflict = managedPathConflict
        self.canUninstallManagedConnector = canUninstallManagedConnector
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
            || managedPathConflict != nil
            || canUninstallManagedConnector != nil
    }

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case auditedEvents = "audited_events"
        case subscribedEvents = "subscribed_events"
        case mappedInformation = "mapped_information"
        case privacyExclusions = "privacy_exclusions"
        case repairableConnectorIssue = "repairable_connector_issue"
        case managedPathConflict = "managed_path_conflict"
        case canUninstallManagedConnector = "can_uninstall_managed_connector"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try container.decodeIfPresent(String.self, forKey: .contractVersion) ?? ""
        auditedEvents = try container.decodeIfPresent([String].self, forKey: .auditedEvents) ?? []
        subscribedEvents = try container.decodeIfPresent([String].self, forKey: .subscribedEvents) ?? []
        mappedInformation = try container.decodeIfPresent([String].self, forKey: .mappedInformation) ?? []
        privacyExclusions = try container.decodeIfPresent([String].self, forKey: .privacyExclusions) ?? []
        repairableConnectorIssue = try container.decodeIfPresent(Bool.self, forKey: .repairableConnectorIssue)
        managedPathConflict = try container.decodeIfPresent(Bool.self, forKey: .managedPathConflict)
        canUninstallManagedConnector = try container.decodeIfPresent(
            Bool.self,
            forKey: .canUninstallManagedConnector
        )
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
    public var nativeFPS: Int
    public var stateDurationsMS: [String: Int]

    public init(
        description: String,
        style: String,
        quality: QualityLevel,
        referenceImages: [String],
        nativeFPS: Int = PetAnimationContract.defaultNativeFPS,
        stateDurationsMS: [String: Int] = PetAnimationContract.defaultStateDurationsMS
    ) {
        precondition(PetAnimationContract.supportedNativeFPS.contains(nativeFPS))
        precondition(PetAnimationContract.hasValidStateDurations(stateDurationsMS))
        self.description = description
        self.style = style
        self.quality = quality
        self.referenceImages = referenceImages
        self.nativeFPS = nativeFPS
        self.stateDurationsMS = stateDurationsMS
    }

    enum CodingKeys: String, CodingKey {
        case description
        case style
        case quality
        case referenceImages = "reference_images"
        case nativeFPS = "native_fps"
        case stateDurationsMS = "state_durations_ms"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        description = try container.decode(String.self, forKey: .description)
        style = try container.decode(String.self, forKey: .style)
        quality = try container.decode(QualityLevel.self, forKey: .quality)
        referenceImages = try container.decode([String].self, forKey: .referenceImages)
        nativeFPS = try container.decodeIfPresent(Int.self, forKey: .nativeFPS)
            ?? PetAnimationContract.defaultNativeFPS
        guard PetAnimationContract.supportedNativeFPS.contains(nativeFPS) else {
            throw DecodingError.dataCorruptedError(
                forKey: .nativeFPS,
                in: container,
                debugDescription: "native_fps must be 10 or 20"
            )
        }
        stateDurationsMS = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .stateDurationsMS
        ) ?? PetAnimationContract.defaultStateDurationsMS
        guard PetAnimationContract.hasValidStateDurations(stateDurationsMS) else {
            throw DecodingError.dataCorruptedError(
                forKey: .stateDurationsMS,
                in: container,
                debugDescription: "state_durations_ms must contain exactly the seven states at 1000 or 2000 ms"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(description, forKey: .description)
        try container.encode(style, forKey: .style)
        try container.encode(quality, forKey: .quality)
        try container.encode(referenceImages, forKey: .referenceImages)
        try container.encode(nativeFPS, forKey: .nativeFPS)
        try container.encode(stateDurationsMS, forKey: .stateDurationsMS)
    }
}
