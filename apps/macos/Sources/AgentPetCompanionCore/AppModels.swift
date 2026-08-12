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
