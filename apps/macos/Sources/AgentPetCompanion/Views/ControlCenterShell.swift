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
    static let supportedMinimumWindowWidth: CGFloat = 760
    static let supportedMinimumWindowHeight: CGFloat = 520
    static let primarySidebarMinimumWidth: CGFloat = 248
    static let primarySidebarIdealWidth: CGFloat = 264
    static let primarySidebarMaximumWidth: CGFloat = 288
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

struct ControlCenterNavigationItem: Identifiable, Equatable {
    let section: NavigationSection
    let title: String
    let systemImage: String
    let isSelected: Bool

    var id: NavigationSection { section }
}

enum ControlCenterNavigationPresentation {
    static let orderedSections: [NavigationSection] = [
        .library,
        .maker,
        .configuration,
        .connections,
        .diagnostics,
    ]

    static func items(
        selection: NavigationSection,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) -> [ControlCenterNavigationItem] {
        orderedSections.map { section in
            ControlCenterNavigationItem(
                section: section,
                title: section.localizedTitle(localeIdentifier: localeIdentifier),
                systemImage: section.systemImage,
                isSelected: section == selection
            )
        }
    }
}

enum PetCoreFailurePresentation {
    static func detail(
        for state: PetCoreOperationalState,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch state {
        case .checking, .recovering: .servicePetCoreRecoveringDetail
        case .offline: .servicePetCoreOfflineDetail
        case .runtimeMismatch: .servicePetCoreRuntimeMismatchDetail
        case .error: .servicePetCoreFailedDetail
        case .online: .servicePetCoreRunning
        }
        return APCLocalization.text(key, locale: localeIdentifier)
    }
}

struct ControlCenterServiceAttentionPresentation: Equatable {
    let title: String
    let systemImage: String
    let appearance: ProductStatusAppearance

    static func resolve(
        for state: PetCoreOperationalState,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) -> Self? {
        switch state {
        case .online, .checking:
            nil
        case .recovering:
            Self(
                title: APCLocalization.text(
                    .serviceToolbarRecovering,
                    locale: localeIdentifier
                ),
                systemImage: "arrow.triangle.2.circlepath.circle.fill",
                appearance: .checking
            )
        case .offline:
            Self(
                title: APCLocalization.text(
                    .serviceToolbarOffline,
                    locale: localeIdentifier
                ),
                systemImage: "network.slash",
                appearance: .error
            )
        case .runtimeMismatch:
            Self(
                title: APCLocalization.text(
                    .serviceToolbarRuntimeMismatch,
                    locale: localeIdentifier
                ),
                systemImage: "exclamationmark.octagon.fill",
                appearance: .attention
            )
        case .error:
            Self(
                title: APCLocalization.text(
                    .serviceToolbarFailure,
                    locale: localeIdentifier
                ),
                systemImage: "exclamationmark.triangle.fill",
                appearance: .error
            )
        }
    }
}

enum ControlCenterRecoveryAction: Hashable {
    case openDiagnostics
}

struct ControlCenterRecoveryBannerPresentation: Equatable {
    let status: ProductStatusPresentation
    let primaryAction: ProductActionPresentation<ControlCenterRecoveryAction>

    static func resolve(
        for state: PetCoreOperationalState,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) -> Self? {
        guard let serviceAttention = ControlCenterServiceAttentionPresentation.resolve(
            for: state,
            localeIdentifier: localeIdentifier
        ) else {
            return nil
        }
        guard state != .recovering else { return nil }

        return Self(
            status: ProductStatusPresentation(
                appearance: serviceAttention.appearance,
                title: serviceAttention.title,
                detail: PetCoreFailurePresentation.detail(
                    for: state,
                    localeIdentifier: localeIdentifier
                )
            ),
            primaryAction: ProductActionPresentation(
                action: .openDiagnostics,
                title: APCLocalization.text(
                    .navigationDiagnostics,
                    locale: localeIdentifier
                ),
                systemImage: "stethoscope",
                accessibilityLabel: APCLocalization.format(
                    .appHelpServiceStatus,
                    locale: localeIdentifier,
                    serviceAttention.title
                )
            )
        )
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
        localizedTitle(localeIdentifier: APCLocalization.interfaceLocaleIdentifier)
    }

    func localizedTitle(localeIdentifier: String) -> String {
        let key: APCLocalizationKey = switch self {
        case .library: .navigationLibrary
        case .maker: .navigationAIPetMaker
        case .configuration: .navigationPetConfiguration
        case .connections: .navigationConnections
        case .diagnostics: .navigationDiagnostics
        }
        return APCLocalization.text(key, locale: localeIdentifier)
    }
}
