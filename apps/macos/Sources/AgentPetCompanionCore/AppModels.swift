import Foundation

public enum NavigationSection: String, CaseIterable, Identifiable, Codable, Sendable {
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
    public var enabled: Bool
    public var statusBubble: Bool
    public var clickMenu: Bool
    public var mousePassthrough: Bool
    public var autoHide: Bool
    public var fpsProfile: FpsProfile
    public var sources: [AgentSource: Bool]
    public var events: [AgentEventKind: Bool]

    public init(
        enabled: Bool = true,
        statusBubble: Bool = true,
        clickMenu: Bool = true,
        mousePassthrough: Bool = false,
        autoHide: Bool = false,
        fpsProfile: FpsProfile = .standard,
        sources: [AgentSource: Bool] = Dictionary(uniqueKeysWithValues: AgentSource.allCases.map { ($0, true) }),
        events: [AgentEventKind: Bool] = Dictionary(uniqueKeysWithValues: AgentEventKind.allCases.map { ($0, true) })
    ) {
        self.enabled = enabled
        self.statusBubble = statusBubble
        self.clickMenu = clickMenu
        self.mousePassthrough = mousePassthrough
        self.autoHide = autoHide
        self.fpsProfile = fpsProfile
        self.sources = sources
        self.events = events
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case statusBubble = "status_bubble"
        case clickMenu = "click_menu"
        case mousePassthrough = "mouse_passthrough"
        case autoHide = "auto_hide"
        case fpsProfile = "fps_profile"
        case sources
        case events
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        statusBubble = try container.decode(Bool.self, forKey: .statusBubble)
        clickMenu = try container.decode(Bool.self, forKey: .clickMenu)
        mousePassthrough = try container.decode(Bool.self, forKey: .mousePassthrough)
        autoHide = try container.decode(Bool.self, forKey: .autoHide)
        fpsProfile = try container.decode(FpsProfile.self, forKey: .fpsProfile)

        let rawSources = try container.decode([String: Bool].self, forKey: .sources)
        sources = Dictionary(uniqueKeysWithValues: AgentSource.allCases.map { source in
            (source, rawSources[source.rawValue] ?? false)
        })

        let rawEvents = try container.decode([String: Bool].self, forKey: .events)
        events = Dictionary(uniqueKeysWithValues: AgentEventKind.allCases.map { event in
            (event, rawEvents[event.rawValue] ?? false)
        })
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(statusBubble, forKey: .statusBubble)
        try container.encode(clickMenu, forKey: .clickMenu)
        try container.encode(mousePassthrough, forKey: .mousePassthrough)
        try container.encode(autoHide, forKey: .autoHide)
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
}

public struct PetSummary: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var style: String
    public var quality: QualityLevel
    public var renderSize: RenderSize
    public var petpackPath: String
    public var coverPath: String
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
        case active
        case createdAt = "created_at"
    }
}

public struct AgentEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var source: AgentSource
    public var eventType: AgentEventKind
    public var title: String
    public var detail: String?
    public var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case eventType = "event_type"
        case title
        case detail
        case createdAt = "created_at"
    }
}

public struct GenerationMessage: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var role: String
    public var content: String
    public var progress: Double
    public var createdAt: String

    public init(id: UUID = UUID(), role: String, content: String, progress: Double, createdAt: String) {
        self.id = id
        self.role = role
        self.content = content
        self.progress = progress
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case progress
        case createdAt = "created_at"
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

    public var title: String {
        switch self {
        case .ok: "正常"
        case .needsFix: "需修复"
        case .missing: "未检测到"
        }
    }
}

public struct AgentConnectionStatus: Codable, Identifiable, Hashable, Sendable {
    public var id: AgentSource { source }
    public var source: AgentSource
    public var items: [ConnectionCheckItem]
    public var installPaths: [String]

    public init(source: AgentSource, items: [ConnectionCheckItem], installPaths: [String]) {
        self.source = source
        self.items = items
        self.installPaths = installPaths
    }

    enum CodingKeys: String, CodingKey {
        case source
        case items
        case installPaths = "install_paths"
    }
}

public struct GenerationForm: Codable, Equatable, Sendable {
    public var description: String
    public var style: String
    public var quality: QualityLevel
    public var referenceImages: [String]
    public var note: String?

    public init(description: String, style: String, quality: QualityLevel, referenceImages: [String], note: String?) {
        self.description = description
        self.style = style
        self.quality = quality
        self.referenceImages = referenceImages
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case description
        case style
        case quality
        case referenceImages = "reference_images"
        case note
    }
}
