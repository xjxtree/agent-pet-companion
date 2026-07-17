import Foundation

public enum NavigationSection: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case studio
    case behavior
    case connections

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .studio: "宠物 Studio"
        case .behavior: "启用与行为"
        case .connections: "Agent 连接"
        }
    }

    public var subtitle: String {
        switch self {
        case .studio: "Pet Studio"
        case .behavior: "Enable & Behavior"
        case .connections: "Agent Connections"
        }
    }

    public var systemImage: String {
        switch self {
        case .studio: "sparkles"
        case .behavior: "switch.2"
        case .connections: "cable.connector"
        }
    }
}

public enum StudioTab: String, CaseIterable, Identifiable, Sendable {
    case new
    case library

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .new: "新建"
        case .library: "宠物库"
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

public enum PetStudioDefaults {
    public static let descriptionText = ""
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
        case .standard: 12
        case .smooth: 20
        }
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

public struct BehaviorSettings: Codable, Equatable, Sendable {
    public static let defaultBubbleTransparency = 0.55

    public var enabled: Bool
    public var statusBubble: Bool
    public var bubbleTransparency: Double
    public var clickMenu: Bool
    public var mousePassthrough: Bool
    public var autoHide: Bool
    public var sessionMessageTimeoutMinutes: Int
    public var fpsProfile: FpsProfile
    public var sources: [AgentSource: Bool]
    public var events: [AgentEventKind: Bool]

    public init(
        enabled: Bool = true,
        statusBubble: Bool = true,
        bubbleTransparency: Double = BehaviorSettings.defaultBubbleTransparency,
        clickMenu: Bool = true,
        mousePassthrough: Bool = true,
        autoHide: Bool = false,
        sessionMessageTimeoutMinutes: Int = 15,
        fpsProfile: FpsProfile = .standard,
        sources: [AgentSource: Bool] = Dictionary(uniqueKeysWithValues: AgentSource.allCases.map { ($0, true) }),
        events: [AgentEventKind: Bool] = Dictionary(uniqueKeysWithValues: AgentEventKind.allCases.map { ($0, true) })
    ) {
        self.enabled = enabled
        self.statusBubble = statusBubble
        self.bubbleTransparency = Self.clampedBubbleTransparency(bubbleTransparency)
        self.clickMenu = clickMenu
        self.mousePassthrough = mousePassthrough
        self.autoHide = autoHide
        self.sessionMessageTimeoutMinutes = sessionMessageTimeoutMinutes
        self.fpsProfile = fpsProfile
        self.sources = sources
        self.events = events
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case statusBubble = "status_bubble"
        case bubbleTransparency = "bubble_transparency"
        case clickMenu = "click_menu"
        case mousePassthrough = "mouse_passthrough"
        case autoHide = "auto_hide"
        case sessionMessageTimeoutMinutes = "session_message_timeout_minutes"
        case fpsProfile = "fps_profile"
        case sources
        case events
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BehaviorSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        statusBubble = try container.decodeIfPresent(Bool.self, forKey: .statusBubble) ?? defaults.statusBubble
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
        try container.encode(bubbleTransparency, forKey: .bubbleTransparency)
        try container.encode(clickMenu, forKey: .clickMenu)
        try container.encode(mousePassthrough, forKey: .mousePassthrough)
        try container.encode(autoHide, forKey: .autoHide)
        try container.encode(sessionMessageTimeoutMinutes, forKey: .sessionMessageTimeoutMinutes)
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
    public var bubbleTransparency: Double?
    public var clickMenu: Bool?
    public var mousePassthrough: Bool?
    public var autoHide: Bool?
    public var sessionMessageTimeoutMinutes: Int?
    public var fpsProfile: FpsProfile?
    public var sources: [AgentSource: Bool]?
    public var events: [AgentEventKind: Bool]?

    public init(from previous: BehaviorSettings, to next: BehaviorSettings) {
        enabled = previous.enabled == next.enabled ? nil : next.enabled
        statusBubble = previous.statusBubble == next.statusBubble ? nil : next.statusBubble
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
        fpsProfile = previous.fpsProfile == next.fpsProfile ? nil : next.fpsProfile
        let changedSources = next.sources.filter { previous.sources[$0.key] != $0.value }
        sources = changedSources.isEmpty ? nil : changedSources
        let changedEvents = next.events.filter { previous.events[$0.key] != $0.value }
        events = changedEvents.isEmpty ? nil : changedEvents
    }

    public var isEmpty: Bool {
        enabled == nil
            && statusBubble == nil
            && bubbleTransparency == nil
            && clickMenu == nil
            && mousePassthrough == nil
            && autoHide == nil
            && sessionMessageTimeoutMinutes == nil
            && fpsProfile == nil
            && sources?.isEmpty != false
            && events?.isEmpty != false
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case statusBubble = "status_bubble"
        case bubbleTransparency = "bubble_transparency"
        case clickMenu = "click_menu"
        case mousePassthrough = "mouse_passthrough"
        case autoHide = "auto_hide"
        case sessionMessageTimeoutMinutes = "session_message_timeout_minutes"
        case fpsProfile = "fps_profile"
        case sources
        case events
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        statusBubble = try container.decodeIfPresent(Bool.self, forKey: .statusBubble)
        bubbleTransparency = try container.decodeIfPresent(Double.self, forKey: .bubbleTransparency)
        clickMenu = try container.decodeIfPresent(Bool.self, forKey: .clickMenu)
        mousePassthrough = try container.decodeIfPresent(Bool.self, forKey: .mousePassthrough)
        autoHide = try container.decodeIfPresent(Bool.self, forKey: .autoHide)
        sessionMessageTimeoutMinutes = try container.decodeIfPresent(
            Int.self,
            forKey: .sessionMessageTimeoutMinutes
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
        try container.encodeIfPresent(bubbleTransparency, forKey: .bubbleTransparency)
        try container.encodeIfPresent(clickMenu, forKey: .clickMenu)
        try container.encodeIfPresent(mousePassthrough, forKey: .mousePassthrough)
        try container.encodeIfPresent(autoHide, forKey: .autoHide)
        try container.encodeIfPresent(
            sessionMessageTimeoutMinutes,
            forKey: .sessionMessageTimeoutMinutes
        )
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
        active: Bool,
        createdAt: String
    ) {
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
        active = try container.decode(Bool.self, forKey: .active)
        createdAt = try container.decode(String.self, forKey: .createdAt)
    }

    public var generationSourceTitle: String {
        switch origin {
        case .verifiedSkillSource:
            "已验证 Skill 来源"
        case .generatedByPetcoreJob:
            provenance == "skill-full-source" ? "App 内生成" : "本地动画预览"
        case .externalImport:
            "外部导入"
        }
    }

    public var generationSourceDetail: String {
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

    public init(
        sessionOpen: Bool? = nil,
        surface: String? = nil,
        terminalApp: String? = nil,
        openURL: String? = nil
    ) {
        self.sessionOpen = sessionOpen
        self.surface = surface
        self.terminalApp = terminalApp
        self.openURL = openURL
    }

    public var explicitlyClosed: Bool { sessionOpen == false }
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
        succeeded(messages) || needsUserInput(messages)
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
        if let kind = message.kind, terminalKinds.contains(kind) {
            return kind
        }
        if message.progress >= 1 {
            if legacyCompletion(message.content) {
                return completedKind
            }
            if legacyCancelation(message.content) {
                return canceledKind
            }
            if message.kind != inputRequestKind {
                return failedKind
            }
        }
        return nil
    }

    private static func legacyCompletion(_ content: String) -> Bool {
        content.contains("完成，可在宠物库启用")
            || content.contains("已保存入库并已启用")
            || content.contains("petpack-source，并已启用")
    }

    private static func legacyCancelation(_ content: String) -> Bool {
        content.contains("已取消生成")
    }
}

public enum GenerationOperation: String, Codable, Hashable, Sendable {
    case create
    case modify
}

public struct GenerationHistory: Codable, Sendable {
    public var found: Bool
    public var petId: String
    public var jobId: String?
    public var status: String?
    public var sessionId: String?
    public var resultPetId: String?
    public var retryOfJobId: String?
    public var operation: GenerationOperation?
    public var createdAt: String?
    public var updatedAt: String?
    public var form: GenerationForm?
    public var messages: [GenerationMessage]

    public init(
        found: Bool,
        petId: String,
        jobId: String? = nil,
        status: String? = nil,
        sessionId: String? = nil,
        resultPetId: String? = nil,
        retryOfJobId: String? = nil,
        operation: GenerationOperation? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        form: GenerationForm? = nil,
        messages: [GenerationMessage] = []
    ) {
        self.found = found
        self.petId = petId
        self.jobId = jobId
        self.status = status
        self.sessionId = sessionId
        self.resultPetId = resultPetId
        self.retryOfJobId = retryOfJobId
        self.operation = operation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.form = form
        self.messages = messages
    }

    enum CodingKeys: String, CodingKey {
        case found
        case petId = "pet_id"
        case jobId = "job_id"
        case status
        case sessionId = "session_id"
        case resultPetId = "result_pet_id"
        case retryOfJobId = "retry_of_job_id"
        case operation
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case form
        case messages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        found = try container.decode(Bool.self, forKey: .found)
        petId = try container.decode(String.self, forKey: .petId)
        jobId = try container.decodeIfPresent(String.self, forKey: .jobId)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        resultPetId = try container.decodeIfPresent(String.self, forKey: .resultPetId)
        retryOfJobId = try container.decodeIfPresent(String.self, forKey: .retryOfJobId)
        operation = try container.decodeIfPresent(GenerationOperation.self, forKey: .operation)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        form = try container.decodeIfPresent(GenerationForm.self, forKey: .form)
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
    public var ownerInstanceID: String?
    public var heartbeatAt: String
    public var messageRevision: String
    public var messages: [GenerationMessage]
    public var inputRequest: GenerationMessage?

    public init(
        jobID: String,
        status: ActiveGenerationStatus,
        form: GenerationForm,
        sessionID: String? = nil,
        resultPetID: String? = nil,
        operation: GenerationOperation? = nil,
        ownerInstanceID: String? = nil,
        heartbeatAt: String,
        messageRevision: String,
        messages: [GenerationMessage],
        inputRequest: GenerationMessage? = nil
    ) {
        self.jobID = jobID
        self.status = status
        self.form = form
        self.sessionID = sessionID
        self.resultPetID = resultPetID
        self.operation = operation
        self.ownerInstanceID = ownerInstanceID
        self.heartbeatAt = heartbeatAt
        self.messageRevision = messageRevision
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
        case ownerInstanceID = "owner_instance_id"
        case heartbeatAt = "heartbeat_at"
        case messageRevision = "message_revision"
        case messages
        case inputRequest = "input_request"
    }
}

public struct ConnectionCheckItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var status: CheckStatus
    public var detail: String

    public init(name: String, status: CheckStatus, detail: String) {
        self.name = name
        self.status = status
        self.detail = detail
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

public struct AgentConnectionStatus: Codable, Identifiable, Hashable, Sendable {
    public var id: AgentSource { source }
    public var source: AgentSource
    public var items: [ConnectionCheckItem]
    public var installPaths: [String]
    public var connectorInstalled: Bool?
    public var checkMode: ConnectionCheckMode
    public var checkedAt: String?

    public init(
        source: AgentSource,
        items: [ConnectionCheckItem],
        installPaths: [String],
        connectorInstalled: Bool? = nil,
        checkMode: ConnectionCheckMode = .runtime,
        checkedAt: String? = nil
    ) {
        self.source = source
        self.items = items
        self.installPaths = installPaths
        self.connectorInstalled = connectorInstalled
        self.checkMode = checkMode
        self.checkedAt = checkedAt
    }

    enum CodingKeys: String, CodingKey {
        case source
        case items
        case installPaths = "install_paths"
        case connectorInstalled = "connector_installed"
        case checkMode = "check_mode"
        case checkedAt = "checked_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(AgentSource.self, forKey: .source)
        items = try container.decode([ConnectionCheckItem].self, forKey: .items)
        installPaths = try container.decode([String].self, forKey: .installPaths)
        connectorInstalled = try container.decodeIfPresent(Bool.self, forKey: .connectorInstalled)
        checkMode = try container.decodeIfPresent(ConnectionCheckMode.self, forKey: .checkMode) ?? .runtime
        checkedAt = try container.decodeIfPresent(String.self, forKey: .checkedAt)
    }

    public var hasInstalledConnectorArtifacts: Bool {
        if let connectorInstalled {
            return connectorInstalled
        }
        return items.contains { item in
            connectorArtifactItemNames.contains(item.name)
                && (item.status == .ok || item.detail.contains("已安装"))
        }
    }

    public var hasRepairableConnectorIssue: Bool {
        !installPaths.isEmpty && items.contains { item in
            repairableConnectorItemNames.contains(item.name) && item.status.isBlocking
        }
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

    private var connectorArtifactItemNames: Set<String> {
        switch source {
        case .codex:
            return ["插件源", "Hook", "Pet Studio Skill", "Codex marketplace", "Codex 插件安装"]
        case .claudeCode:
            return ["Hooks", "事件通道", "Claude settings.json"]
        case .pi:
            return ["Extension"]
        case .opencode:
            return ["Plugin"]
        }
    }

    private var repairableConnectorItemNames: Set<String> {
        connectorArtifactItemNames
    }
}

public struct GenerationForm: Codable, Equatable, Sendable {
    public var description: String
    public var style: String
    public var quality: QualityLevel
    public var referenceImages: [String]

    public init(description: String, style: String, quality: QualityLevel, referenceImages: [String]) {
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
}
