import AgentPetCompanionCore
import SwiftUI

enum ControlCenterShellMode: Equatable, Sendable {
    case allColumns
    case sidebarAndContent
    case singleContent

    var keepsInspectorPresented: Bool {
        self == .allColumns
    }
}

struct ControlCenterShellPolicy: Equatable, Sendable {
    static let fullLayoutMinimumWidth: CGFloat = 1_120
    static let sidebarLayoutMinimumWidth: CGFloat = 880

    let windowWidth: CGFloat

    var mode: ControlCenterShellMode {
        if windowWidth >= Self.fullLayoutMinimumWidth {
            .allColumns
        } else if windowWidth >= Self.sidebarLayoutMinimumWidth {
            .sidebarAndContent
        } else {
            .singleContent
        }
    }

    var preferredColumnVisibility: NavigationSplitViewVisibility {
        switch mode {
        case .allColumns, .sidebarAndContent:
            .all
        case .singleContent:
            .detailOnly
        }
    }
}

private struct ControlCenterShellModeKey: EnvironmentKey {
    static let defaultValue = ControlCenterShellMode.allColumns
}

extension EnvironmentValues {
    var controlCenterShellMode: ControlCenterShellMode {
        get { self[ControlCenterShellModeKey.self] }
        set { self[ControlCenterShellModeKey.self] = newValue }
    }
}

extension NavigationSection {
    var localizedTitle: String {
        let key: APCLocalizationKey = switch self {
        case .library: .navigationLibrary
        case .maker: .navigationAIPetMaker
        case .configuration: .navigationPetConfiguration
        case .connections: .navigationConnections
        case .diagnostics: .navigationDiagnostics
        }
        return APCLocalization.text(key)
    }
}
