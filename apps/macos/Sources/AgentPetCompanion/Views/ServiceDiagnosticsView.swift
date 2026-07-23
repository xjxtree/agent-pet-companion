import AgentPetCompanionCore
import SwiftUI

enum ServiceDiagnosticKind: String, CaseIterable, Identifiable {
    case petCore
    case localRPC
    case eventChannel
    case desktopPet

    var id: String { rawValue }
}

enum ServiceDiagnosticTone: Equatable {
    case healthy
    case checking
    case warning
    case failure
    case inactive

    var color: Color {
        switch self {
        case .healthy:
            APCDesign.success
        case .checking:
            APCDesign.accent
        case .warning:
            .orange
        case .failure:
            APCDesign.destructive
        case .inactive:
            APCDesign.textSecondary
        }
    }

    var systemImage: String {
        switch self {
        case .healthy:
            "checkmark.circle.fill"
        case .checking:
            "clock.fill"
        case .warning:
            "exclamationmark.octagon.fill"
        case .failure:
            "exclamationmark.triangle.fill"
        case .inactive:
            "minus.circle.fill"
        }
    }
}

struct ServiceDiagnosticRowPresentation: Identifiable, Equatable {
    let id: ServiceDiagnosticKind
    let title: String
    let detail: String
    let status: String
    let tone: ServiceDiagnosticTone
}

struct ServiceToolbarPresentation: Equatable {
    let title: String
    let systemImage: String
    let tone: ServiceDiagnosticTone
}

struct ServiceDiagnosticsPresentation: Equatable {
    let rows: [ServiceDiagnosticRowPresentation]

    init(
        operationalState: PetCoreOperationalState,
        runtimeInfo: PetCoreRuntimeInfo,
        recentEventSummary: String?,
        desktopPetEnabled: Bool,
        desktopPetVisible: Bool,
        activePetName: String?,
        framesPerSecond: Int,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) {
        rows = [
            Self.petCoreRow(
                operationalState: operationalState,
                runtimeInfo: runtimeInfo,
                locale: localeIdentifier
            ),
            Self.localRPCRow(
                operationalState: operationalState,
                runtimeInfo: runtimeInfo,
                locale: localeIdentifier
            ),
            Self.eventChannelRow(
                operationalState: operationalState,
                recentEventSummary: recentEventSummary,
                locale: localeIdentifier
            ),
            Self.desktopPetRow(
                enabled: desktopPetEnabled,
                visible: desktopPetVisible,
                activePetName: activePetName,
                framesPerSecond: framesPerSecond,
                locale: localeIdentifier
            )
        ]
    }

    // Source-compatible bridge for older callers. The localized presentation
    // intentionally does not render AppStore's legacy global status string.
    init(
        runtimeInfo: PetCoreRuntimeInfo,
        recentEventSummary: String?,
        desktopPetEnabled: Bool,
        desktopPetVisible: Bool,
        activePetName: String?,
        framesPerSecond: Int,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) {
        self.init(
            operationalState: Self.legacyOperationalState(runtimeInfo),
            runtimeInfo: runtimeInfo,
            recentEventSummary: recentEventSummary,
            desktopPetEnabled: desktopPetEnabled,
            desktopPetVisible: desktopPetVisible,
            activePetName: activePetName,
            framesPerSecond: framesPerSecond,
            localeIdentifier: localeIdentifier
        )
    }

    init(
        runtimeInfo: PetCoreRuntimeInfo,
        serviceStatusText _: String,
        recentEventSummary: String?,
        desktopPetEnabled: Bool,
        desktopPetVisible: Bool,
        activePetName: String?,
        framesPerSecond: Int,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) {
        self.init(
            operationalState: Self.legacyOperationalState(runtimeInfo),
            runtimeInfo: runtimeInfo,
            recentEventSummary: recentEventSummary,
            desktopPetEnabled: desktopPetEnabled,
            desktopPetVisible: desktopPetVisible,
            activePetName: activePetName,
            framesPerSecond: framesPerSecond,
            localeIdentifier: localeIdentifier
        )
    }

    static func toolbar(
        operationalState: PetCoreOperationalState,
        runtimeInfo: PetCoreRuntimeInfo,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) -> ServiceToolbarPresentation {
        return switch operationalState {
        case .checking:
            ServiceToolbarPresentation(
                title: APCLocalization.text(.serviceToolbarChecking, locale: localeIdentifier),
                systemImage: "clock.arrow.circlepath",
                tone: .checking
            )
        case .recovering:
            ServiceToolbarPresentation(
                title: APCLocalization.text(.serviceToolbarRecovering, locale: localeIdentifier),
                systemImage: "arrow.triangle.2.circlepath.circle.fill",
                tone: .checking
            )
        case .online:
            ServiceToolbarPresentation(
                title: APCLocalization.text(.serviceToolbarHealthy, locale: localeIdentifier),
                systemImage: "checkmark.circle.fill",
                tone: .healthy
            )
        case .offline:
            ServiceToolbarPresentation(
                title: APCLocalization.text(.serviceToolbarOffline, locale: localeIdentifier),
                systemImage: "network.slash",
                tone: .failure
            )
        case .runtimeMismatch:
            ServiceToolbarPresentation(
                title: APCLocalization.text(.serviceToolbarRuntimeMismatch, locale: localeIdentifier),
                systemImage: "exclamationmark.octagon.fill",
                tone: .warning
            )
        case .error:
            ServiceToolbarPresentation(
                title: APCLocalization.text(.serviceToolbarFailure, locale: localeIdentifier),
                systemImage: "exclamationmark.triangle.fill",
                tone: .failure
            )
        }
    }

    static func toolbar(
        runtimeInfo: PetCoreRuntimeInfo,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) -> ServiceToolbarPresentation {
        toolbar(
            operationalState: legacyOperationalState(runtimeInfo),
            runtimeInfo: runtimeInfo,
            localeIdentifier: localeIdentifier
        )
    }

    func row(_ kind: ServiceDiagnosticKind) -> ServiceDiagnosticRowPresentation? {
        rows.first { $0.id == kind }
    }

    private static func petCoreRow(
        operationalState: PetCoreOperationalState,
        runtimeInfo: PetCoreRuntimeInfo,
        locale: String
    ) -> ServiceDiagnosticRowPresentation {
        switch operationalState {
        case .checking:
            return ServiceDiagnosticRowPresentation(
                id: .petCore,
                title: APCLocalization.text(.technicalPetCore, locale: locale),
                detail: APCLocalization.text(.servicePetCoreCheckingDetail, locale: locale),
                status: APCLocalization.text(.serviceStatusChecking, locale: locale),
                tone: .checking
            )
        case .recovering:
            return ServiceDiagnosticRowPresentation(
                id: .petCore,
                title: APCLocalization.text(.technicalPetCore, locale: locale),
                detail: APCLocalization.text(.servicePetCoreRecoveringDetail, locale: locale),
                status: APCLocalization.text(.serviceStatusRecovering, locale: locale),
                tone: .checking
            )
        case .online:
            return ServiceDiagnosticRowPresentation(
                id: .petCore,
                title: APCLocalization.text(.technicalPetCore, locale: locale),
                detail: runtimeInfo.version.map {
                    APCLocalization.format(.servicePetCoreRunningVersionFormat, locale: locale, $0)
                } ?? APCLocalization.text(.servicePetCoreRunning, locale: locale),
                status: APCLocalization.text(.serviceStatusHealthy, locale: locale),
                tone: .healthy
            )
        case .offline:
            return ServiceDiagnosticRowPresentation(
                id: .petCore,
                title: APCLocalization.text(.technicalPetCore, locale: locale),
                detail: APCLocalization.text(.servicePetCoreOfflineDetail, locale: locale),
                status: APCLocalization.text(.serviceStatusOffline, locale: locale),
                tone: .failure
            )
        case .runtimeMismatch:
            return ServiceDiagnosticRowPresentation(
                id: .petCore,
                title: APCLocalization.text(.technicalPetCore, locale: locale),
                detail: APCLocalization.text(.servicePetCoreRuntimeMismatchDetail, locale: locale),
                status: APCLocalization.text(.serviceStatusRuntimeMismatch, locale: locale),
                tone: .warning
            )
        case .error:
            return ServiceDiagnosticRowPresentation(
                id: .petCore,
                title: APCLocalization.text(.technicalPetCore, locale: locale),
                detail: APCLocalization.text(.servicePetCoreFailedDetail, locale: locale),
                status: APCLocalization.text(.serviceStatusFailure, locale: locale),
                tone: .failure
            )
        }
    }

    private static func localRPCRow(
        operationalState: PetCoreOperationalState,
        runtimeInfo: PetCoreRuntimeInfo,
        locale: String
    ) -> ServiceDiagnosticRowPresentation {
        switch operationalState {
        case .checking:
            return ServiceDiagnosticRowPresentation(
                id: .localRPC,
                title: APCLocalization.text(.serviceRowLocalRPC, locale: locale),
                detail: APCLocalization.text(.serviceRPCCheckingDetail, locale: locale),
                status: APCLocalization.text(.serviceStatusChecking, locale: locale),
                tone: .checking
            )
        case .recovering:
            return ServiceDiagnosticRowPresentation(
                id: .localRPC,
                title: APCLocalization.text(.serviceRowLocalRPC, locale: locale),
                detail: APCLocalization.text(.serviceRPCRecoveringDetail, locale: locale),
                status: APCLocalization.text(.serviceStatusRecovering, locale: locale),
                tone: .checking
            )
        case .online:
            let protocolVersion = runtimeInfo.rpcProtocol
                ?? APCLocalization.text(.serviceRPCProtocolUnknown, locale: locale)
            let schema = runtimeInfo.databaseSchemaRange.map { "Schema \($0)" }
                ?? APCLocalization.text(.serviceRPCSchemaUnreported, locale: locale)
            return ServiceDiagnosticRowPresentation(
                id: .localRPC,
                title: APCLocalization.text(.serviceRowLocalRPC, locale: locale),
                detail: "\(protocolVersion) · \(schema)",
                status: APCLocalization.text(.serviceStatusHealthy, locale: locale),
                tone: .healthy
            )
        case .offline:
            return ServiceDiagnosticRowPresentation(
                id: .localRPC,
                title: APCLocalization.text(.serviceRowLocalRPC, locale: locale),
                detail: APCLocalization.text(.serviceRPCOfflineDetail, locale: locale),
                status: APCLocalization.text(.serviceStatusOffline, locale: locale),
                tone: .failure
            )
        case .runtimeMismatch:
            return ServiceDiagnosticRowPresentation(
                id: .localRPC,
                title: APCLocalization.text(.serviceRowLocalRPC, locale: locale),
                detail: APCLocalization.text(.serviceRPCRuntimeMismatchDetail, locale: locale),
                status: APCLocalization.text(.serviceStatusRuntimeMismatch, locale: locale),
                tone: .warning
            )
        case .error:
            return ServiceDiagnosticRowPresentation(
                id: .localRPC,
                title: APCLocalization.text(.serviceRowLocalRPC, locale: locale),
                detail: APCLocalization.text(.serviceRPCUnavailable, locale: locale),
                status: APCLocalization.text(.serviceStatusFailure, locale: locale),
                tone: .failure
            )
        }
    }

    private static func eventChannelRow(
        operationalState: PetCoreOperationalState,
        recentEventSummary: String?,
        locale: String
    ) -> ServiceDiagnosticRowPresentation {
        switch operationalState {
        case .checking:
            return ServiceDiagnosticRowPresentation(
                id: .eventChannel,
                title: APCLocalization.text(.serviceRowEventChannel, locale: locale),
                detail: APCLocalization.text(.serviceEventCheckingDetail, locale: locale),
                status: APCLocalization.text(.serviceStatusChecking, locale: locale),
                tone: .checking
            )
        case .recovering:
            return ServiceDiagnosticRowPresentation(
                id: .eventChannel,
                title: APCLocalization.text(.serviceRowEventChannel, locale: locale),
                detail: APCLocalization.text(.serviceEventRecoveringDetail, locale: locale),
                status: APCLocalization.text(.serviceStatusRecovering, locale: locale),
                tone: .checking
            )
        case .online:
            return ServiceDiagnosticRowPresentation(
                id: .eventChannel,
                title: APCLocalization.text(.serviceRowEventChannel, locale: locale),
                detail: recentEventSummary.map {
                    APCLocalization.format(.serviceEventRecentFormat, locale: locale, $0)
                } ?? APCLocalization.text(.appStateNoRecentActivity, locale: locale),
                status: APCLocalization.text(.serviceStatusOnline, locale: locale),
                tone: .healthy
            )
        case .offline:
            return ServiceDiagnosticRowPresentation(
                id: .eventChannel,
                title: APCLocalization.text(.serviceRowEventChannel, locale: locale),
                detail: APCLocalization.text(.serviceEventOfflineDetail, locale: locale),
                status: APCLocalization.text(.serviceStatusOffline, locale: locale),
                tone: .failure
            )
        case .runtimeMismatch:
            return ServiceDiagnosticRowPresentation(
                id: .eventChannel,
                title: APCLocalization.text(.serviceRowEventChannel, locale: locale),
                detail: APCLocalization.text(.serviceEventRuntimeMismatchDetail, locale: locale),
                status: APCLocalization.text(.serviceStatusRuntimeMismatch, locale: locale),
                tone: .warning
            )
        case .error:
            return ServiceDiagnosticRowPresentation(
                id: .eventChannel,
                title: APCLocalization.text(.serviceRowEventChannel, locale: locale),
                detail: APCLocalization.text(.serviceEventWaiting, locale: locale),
                status: APCLocalization.text(.serviceStatusFailure, locale: locale),
                tone: .failure
            )
        }
    }

    private static func legacyOperationalState(
        _ runtimeInfo: PetCoreRuntimeInfo
    ) -> PetCoreOperationalState {
        switch runtimeInfo.phase {
        case .checking: .checking
        case .running: .online
        case .failed: .error
        }
    }

    private static func desktopPetRow(
        enabled: Bool,
        visible: Bool,
        activePetName: String?,
        framesPerSecond: Int,
        locale: String
    ) -> ServiceDiagnosticRowPresentation {
        guard enabled else {
            return ServiceDiagnosticRowPresentation(
                id: .desktopPet,
                title: APCLocalization.text(.serviceRowDesktopPet, locale: locale),
                detail: APCLocalization.text(.serviceDesktopDisabled, locale: locale),
                status: APCLocalization.text(.serviceStatusDisabled, locale: locale),
                tone: .inactive
            )
        }
        guard visible else {
            return ServiceDiagnosticRowPresentation(
                id: .desktopPet,
                title: APCLocalization.text(.serviceRowDesktopPet, locale: locale),
                detail: APCLocalization.text(.serviceDesktopHidden, locale: locale),
                status: APCLocalization.text(.serviceStatusHidden, locale: locale),
                tone: .inactive
            )
        }
        let petName = activePetName ?? APCLocalization.text(.appStateNoPetEnabled, locale: locale)
        return ServiceDiagnosticRowPresentation(
            id: .desktopPet,
            title: APCLocalization.text(.serviceRowDesktopPet, locale: locale),
            detail: APCLocalization.format(
                .serviceDesktopRunningFormat,
                locale: locale,
                framesPerSecond,
                petName
            ),
            status: APCLocalization.text(.serviceStatusHealthy, locale: locale),
            tone: .healthy
        )
    }
}

extension ServiceDiagnosticsPrimaryAction {
    static func resolve(for state: PetCoreOperationalState) -> Self {
        ServiceDiagnosticsProductPresentation(
            operationalState: state
        ).primaryAction
    }
}

struct ServiceDiagnosticsAggregatePresentation: Equatable {
    let health: ServiceDiagnosticsHealthState
    let status: ProductStatusPresentation
    let summary: String
    let primaryAction: ProductActionPresentation<ServiceDiagnosticsPrimaryAction>?

    init(
        operationalState: PetCoreOperationalState,
        actionIsBusy: Bool = false,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) {
        let product = ServiceDiagnosticsProductPresentation(
            operationalState: operationalState
        )
        health = product.health

        let toolbar = ServiceDiagnosticsPresentation.toolbar(
            operationalState: operationalState,
            runtimeInfo: .initial(manifest: nil),
            localeIdentifier: localeIdentifier
        )
        status = ProductStatusPresentation(
            appearance: Self.appearance(for: product.health),
            title: toolbar.title
        )
        summary = APCLocalization.text(
            Self.summaryKey(for: operationalState),
            locale: localeIdentifier
        )

        guard let title = APCLocalizedPresentation.primaryActionTitle(
            product.primaryAction,
            locale: localeIdentifier
        ) else {
            primaryAction = nil
            return
        }
        primaryAction = ProductActionPresentation(
            action: product.primaryAction,
            title: title,
            systemImage: Self.systemImage(for: product.primaryAction),
            isEnabled: !actionIsBusy
        )
    }

    private static func appearance(
        for health: ServiceDiagnosticsHealthState
    ) -> ProductStatusAppearance {
        switch health {
        case .checking:
            .checking
        case .healthy:
            .normal
        case .needsRecovery:
            .attention
        case .unavailable:
            .error
        }
    }

    private static func summaryKey(
        for state: PetCoreOperationalState
    ) -> APCLocalizationKey {
        switch state {
        case .online:
            .diagnosticsSummaryHealthy
        case .checking:
            .diagnosticsSummaryChecking
        case .recovering:
            .diagnosticsSummaryRecovering
        case .offline:
            .diagnosticsSummaryOffline
        case .runtimeMismatch:
            .diagnosticsSummaryRuntimeMismatch
        case .error:
            .diagnosticsSummaryFailure
        }
    }

    private static func systemImage(
        for action: ServiceDiagnosticsPrimaryAction
    ) -> String? {
        switch action {
        case .refresh:
            "arrow.clockwise"
        case .recover:
            "wrench.and.screwdriver"
        case .retry:
            "arrow.clockwise"
        case .unavailable:
            nil
        }
    }
}

struct ServiceDiagnosticsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isRefreshing = false
    @State private var isTechnicalDetailsExpanded = false

    private var presentation: ServiceDiagnosticsPresentation {
        ServiceDiagnosticsPresentation(
            operationalState: store.petCoreOperationalState,
            runtimeInfo: store.petCoreRuntimeInfo,
            recentEventSummary: nil,
            desktopPetEnabled: store.behavior.enabled,
            desktopPetVisible: store.overlayVisible,
            activePetName: store.activePet?.name,
            framesPerSecond: store.effectiveFPSProfile.fps
        )
    }

    private var primaryAction: ServiceDiagnosticsPrimaryAction {
        .resolve(for: store.petCoreOperationalState)
    }

    private var serviceActionIsBusy: Bool {
        isRefreshing
            || store.petCoreOperationalState == .checking
            || store.petCoreOperationalState == .recovering
    }

    private var aggregatePresentation: ServiceDiagnosticsAggregatePresentation {
        ServiceDiagnosticsAggregatePresentation(
            operationalState: store.petCoreOperationalState,
            actionIsBusy: serviceActionIsBusy
        )
    }

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 18) {
                overallHealthRegion
                diagnosticPackageRegion
                technicalDetailsRegion
            }
            .frame(maxWidth: 860, alignment: .topLeading)
            .accessibilityIdentifier("diagnostics.layout.single-column")
        }
        .accessibilityIdentifier("diagnostics.page")
    }

    private var overallHealthRegion: some View {
        PrimaryExperienceCard(
            identity: ProductComponentIdentity(
                scope: "diagnostics",
                instance: "service"
            ),
            title: APCLocalization.text(.diagnosticsServiceStatus),
            summary: aggregatePresentation.summary,
            status: aggregatePresentation.status,
            primaryAction: aggregatePresentation.primaryAction
        ) { _ in
            performServiceAction()
        } content: {
            EmptyView()
        }
        .accessibilityIdentifier("diagnostics.service-summary")
    }

    private var technicalDetailsRegion: some View {
        AdvancedDetailsDisclosure(
            identity: ProductComponentIdentity(
                scope: "diagnostics",
                instance: "technical"
            ),
            title: APCLocalization.text(.diagnosticsTechnicalTitle),
            summary: APCLocalization.text(.diagnosticsTechnicalSummary),
            isExpanded: $isTechnicalDetailsExpanded
        ) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(presentation.rows) { row in
                    ServiceDiagnosticRow(presentation: row)
                    if row.id != presentation.rows.last?.id {
                        Divider()
                    }
                }

                Divider()
                    .padding(.vertical, 10)

                Text(diagnosticPackageSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("diagnostics.technical-details")
    }

    private var diagnosticPackageRegion: some View {
        Surface {
            VStack(alignment: .leading, spacing: 16) {
                Label(
                    APCLocalization.text(.diagnosticsPackageTitle),
                    systemImage: "doc.zipper"
                )
                    .font(.title3.weight(.semibold))

                Text(APCLocalization.text(.diagnosticsPrivacy))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(APCLocalization.text(.diagnosticsPrivacy))
                    .accessibilityHint(APCLocalization.text(.diagnosticsPrivacy))

                Button {
                    performDiagnosticsArchiveAction()
                } label: {
                    diagnosticExportButtonLabel
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.diagnosticsExportState.primaryAction == nil)
                .accessibilityIdentifier("diagnostics.export")

                if let exportStatusMessage {
                    Text(exportStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

            }
        }
        .accessibilityIdentifier("diagnostics.log-package")
    }

    private var diagnosticPackageSummary: String {
        [
            APCLocalization.text(.diagnosticsPackageDetail),
            APCLocalization.text(.diagnosticsMetadataBounded14Days),
            APCLocalization.text(.diagnosticsMetadataRedacted),
            APCLocalization.text(.technicalZIP),
        ].joined(separator: " · ")
    }

    private var exportStatusMessage: String? {
        store.diagnosticsExportState.displayMessage()
    }

    @ViewBuilder
    private var diagnosticExportButtonLabel: some View {
        switch store.diagnosticsExportState {
        case .exporting:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(APCLocalization.text(.diagnosticsExporting))
            }
        case .saving:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(APCLocalization.text(.diagnosticsLogDownload))
            }
        case .ready, .saveFailed:
            Label(
                APCLocalization.text(.diagnosticsLogDownload),
                systemImage: "square.and.arrow.down"
            )
        case .idle, .succeeded, .failed:
            Label(
                APCLocalization.text(.diagnosticsExport),
                systemImage: "arrow.down.doc"
            )
        }
    }

    private func performDiagnosticsArchiveAction() {
        switch store.diagnosticsExportState.primaryAction {
        case .prepare:
            store.prepareDiagnosticsExport()
        case .save:
            store.savePreparedDiagnosticsArchive()
        case nil:
            break
        }
    }

    private func performServiceAction() {
        guard !isRefreshing, primaryAction != .unavailable else { return }
        isRefreshing = true
        Task { @MainActor in
            switch primaryAction {
            case .refresh, .retry:
                _ = await store.refresh()
            case .recover:
                _ = await store.recoverServiceConnection()
            case .unavailable:
                break
            }
            isRefreshing = false
        }
    }
}

private struct ServiceDiagnosticRow: View {
    let presentation: ServiceDiagnosticRowPresentation

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: presentation.tone.systemImage)
                .foregroundStyle(presentation.tone.color)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.headline)
                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .padding(.vertical, 11)
        .help(presentation.status)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(APCLocalization.format(
            .diagnosticsRowAccessibilityFormat,
            presentation.title,
            presentation.status,
            presentation.detail
        ))
        .accessibilityValue(presentation.status)
        .accessibilityIdentifier("diagnostics.service.\(presentation.id.rawValue)")
    }
}
