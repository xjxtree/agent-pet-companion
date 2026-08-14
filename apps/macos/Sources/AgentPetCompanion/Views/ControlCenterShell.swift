import AgentPetCompanionCore
import SwiftUI

enum ControlCenterShellMode: Equatable, Sendable {
    case allColumns
    case sidebarAndContent
    case singleContent
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

enum ControlCenterAgentConnectionAction: Hashable {
    case openConnections
}

struct ControlCenterAgentConnectionBannerPresentation: Equatable {
    let status: ProductStatusPresentation
    let primaryAction: ProductActionPresentation<ControlCenterAgentConnectionAction>
    let affectedSources: [AgentSource]

    static func resolve(
        startupState: AppStartupConnectionCheckState,
        connections: [AgentConnectionStatus],
        operationState: AgentConnectionOperationState,
        serviceState: PetCoreOperationalState,
        convergenceState: AppUpdateConvergenceState,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) -> Self? {
        guard serviceState == .online else { return nil }
        if case .needsAttention(.connectors) = convergenceState {
            // The post-update banner already names the affected Agents and
            // owns its scoped recovery/recheck actions.
            return nil
        }

        if case let .failed(failure) = operationState {
            return failed(
                reason: failure.reason,
                sources: failure.operation.sources,
                localeIdentifier: localeIdentifier
            )
        }

        switch startupState {
        case .idle, .waiting:
            return nil
        case .checking:
            return checking(localeIdentifier: localeIdentifier)
        case let .failed(reason):
            return failed(
                reason: reason,
                sources: AgentSource.allCases,
                localeIdentifier: localeIdentifier
            )
        case .completed:
            break
        }

        let issues = AgentSource.allCases.compactMap { source in
            issue(
                for: source,
                status: connections.first { $0.source == source },
                localeIdentifier: localeIdentifier
            )
        }
        guard !issues.isEmpty else { return nil }

        let detail = issues.map { issue in
            APCLocalization.format(
                .appAgentConnectionsIssueSourceFormat,
                locale: localeIdentifier,
                issue.source.title,
                issue.summary
            )
        }.joined(separator: localeIdentifier.lowercased().hasPrefix("zh") ? "；" : "; ")

        return Self(
            status: ProductStatusPresentation(
                appearance: .attention,
                title: APCLocalization.text(
                    .appAgentConnectionsAttentionTitle,
                    locale: localeIdentifier
                ),
                detail: APCLocalization.format(
                    .appAgentConnectionsAttentionDetailFormat,
                    locale: localeIdentifier,
                    detail
                )
            ),
            primaryAction: openConnectionsAction(localeIdentifier: localeIdentifier),
            affectedSources: issues.map(\.source)
        )
    }

    private struct Issue {
        let source: AgentSource
        let summary: String
    }

    private static func issue(
        for source: AgentSource,
        status: AgentConnectionStatus?,
        localeIdentifier: String
    ) -> Issue? {
        let presentation = AgentConnectionProductPresentation(
            source: source,
            status: status,
            operationState: .idle
        )
        guard let status else {
            return Issue(
                source: source,
                summary: APCLocalization.text(
                    .appAgentConnectionsIssueIncomplete,
                    locale: localeIdentifier
                )
            )
        }
        if status.hasManagedPathConflict {
            return Issue(
                source: source,
                summary: APCLocalization.text(
                    .appAgentConnectionsIssuePathConflict,
                    locale: localeIdentifier
                )
            )
        }
        if presentation.health == .needsRepair
            || presentation.managedComponents.contains(where: managedComponentNeedsUpdate)
        {
            return Issue(
                source: source,
                summary: APCLocalization.text(
                    .appAgentConnectionsIssuePluginUpdate,
                    locale: localeIdentifier
                )
            )
        }
        if AgentConnectionsPresentation.attentionReason(for: presentation) != nil {
            return Issue(
                source: source,
                summary: AgentConnectionsPresentation.healthTitle(
                    for: presentation,
                    locale: localeIdentifier
                )
            )
        }
        // A runtime result is intentionally cached for only a bounded period.
        // Once it expires, PetCore resumes publishing an authoritative light
        // snapshot. A complete, healthy light snapshot still proves that the
        // local integration has no current actionable issue; it must not turn
        // an earlier successful full check into an "incomplete result" alert.
        if presentation.hasCurrentLightSnapshot {
            return nil
        }
        guard presentation.hasCurrentTypedSnapshot else {
            return Issue(
                source: source,
                summary: APCLocalization.text(
                    .appAgentConnectionsIssueIncomplete,
                    locale: localeIdentifier
                )
            )
        }
        if presentation.health == .notChecked || presentation.health == .unavailable {
            return Issue(
                source: source,
                summary: APCLocalization.text(
                    .appAgentConnectionsIssueIncomplete,
                    locale: localeIdentifier
                )
            )
        }
        return nil
    }

    private static func managedComponentNeedsUpdate(
        _ component: AgentManagedComponent
    ) -> Bool {
        component.status.isBlocking
            || component.contentMatches == false
            || (
                component.expectedVersion != nil
                    && component.activeVersion != nil
                    && component.expectedVersion != component.activeVersion
            )
    }

    private static func checking(localeIdentifier: String) -> Self {
        Self(
            status: ProductStatusPresentation(
                appearance: .checking,
                title: APCLocalization.text(
                    .appAgentConnectionsCheckingTitle,
                    locale: localeIdentifier
                ),
                detail: APCLocalization.text(
                    .appAgentConnectionsCheckingDetail,
                    locale: localeIdentifier
                )
            ),
            primaryAction: openConnectionsAction(localeIdentifier: localeIdentifier),
            affectedSources: AgentSource.allCases
        )
    }

    private static func failed(
        reason: AgentConnectionOperationFailureReason,
        sources: [AgentSource],
        localeIdentifier: String
    ) -> Self {
        Self(
            status: ProductStatusPresentation(
                appearance: .error,
                title: APCLocalization.text(
                    .appAgentConnectionsCheckFailedTitle,
                    locale: localeIdentifier
                ),
                detail: APCLocalization.format(
                    .appAgentConnectionsCheckFailedDetailFormat,
                    locale: localeIdentifier,
                    AgentConnectionsPresentation.operationFailureDetail(
                        reason,
                        locale: localeIdentifier
                    )
                )
            ),
            primaryAction: openConnectionsAction(localeIdentifier: localeIdentifier),
            affectedSources: sources
        )
    }

    private static func openConnectionsAction(
        localeIdentifier: String
    ) -> ProductActionPresentation<ControlCenterAgentConnectionAction> {
        ProductActionPresentation(
            action: .openConnections,
            title: APCLocalization.text(
                .navigationConnections,
                locale: localeIdentifier
            ),
            systemImage: "link",
            accessibilityLabel: APCLocalization.text(
                .appActionCheckConnections,
                locale: localeIdentifier
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
