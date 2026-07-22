import AgentPetCompanionCore
import AppKit
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

struct ControlCenterWindowTitleUpdater: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> WindowTitleHostView {
        WindowTitleHostView(title: title)
    }

    func updateNSView(_ nsView: WindowTitleHostView, context: Context) {
        nsView.title = title
    }
}

final class WindowTitleHostView: NSView {
    var title: String {
        didSet { applyTitle() }
    }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTitle()
    }

    private func applyTitle() {
        window?.title = title
    }
}
