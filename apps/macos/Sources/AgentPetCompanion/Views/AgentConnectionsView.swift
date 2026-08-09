import AgentPetCompanionCore
import SwiftUI

enum AgentConnectionsCatalog {
    static let sources: [AgentSource] = [.codex, .claudeCode, .pi, .opencode]
}

enum AgentConnectionVisualTone: Equatable {
    case good
    case warning
    case destructive
    case neutral

    var color: Color {
        switch self {
        case .good: APCDesign.success
        case .warning: APCDesign.warning
        case .destructive: APCDesign.destructive
        case .neutral: APCDesign.textSecondary
        }
    }
}

enum AgentConnectionMoreAction: Equatable {
    case recheck
    case sendTestMessage
    case setUpAgain
    case remove
}

struct AgentConnectionActionLayout: Equatable {
    let primaryAction: AgentConnectionPrimaryAction?
    let moreActions: [AgentConnectionMoreAction]
}

enum AgentConnectionAttentionReason: Equatable {
    case managedRepair
    case agentMissing
    case updateRequired
    case hookAuthorization
    case permissionRequired
    case restartRequired
    case localConnectionIssue
    case actionRequired
}

enum AgentConnectionsPresentation {
    static func repairableStatuses(
        from statuses: [AgentConnectionStatus]
    ) -> [AgentConnectionStatus] {
        AgentConnectionsCatalog.sources.compactMap { source in
            guard let status = statuses.first(where: { $0.source == source }) else {
                return nil
            }
            let presentation = AgentConnectionProductPresentation(
                source: source,
                status: status,
                operationState: .idle
            )
            guard presentation.canRepairManagedConnector,
                  presentation.primaryAction == .connect
                    || presentation.primaryAction == .repair else {
                return nil
            }
            return status
        }
    }

    static func manageableStatuses(
        from statuses: [AgentConnectionStatus]
    ) -> [AgentConnectionStatus] {
        AgentConnectionsCatalog.sources.compactMap { source in
            guard let status = statuses.first(where: { $0.source == source }) else {
                return nil
            }
            let presentation = AgentConnectionProductPresentation(
                source: source,
                status: status,
                operationState: .idle
            )
            return presentation.canManageManagedConnector ? status : nil
        }
    }

    static func managedRepairConfirmationMessage(
        for statuses: [AgentConnectionStatus],
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        guard !statuses.isEmpty else {
            return APCLocalization.text(.connectionsNoRepairAll, locale: locale)
        }

        let names = statuses.map(\.source.title).joined(separator: ", ")
        var lines = [APCLocalization.format(
            .connectionsManagedChangeFormat,
            locale: locale,
            APCLocalization.text(.connectionsActionInstallUpdate, locale: locale),
            names
        )]
        let paths = statuses.flatMap(\.installPaths)
        lines.append(contentsOf: paths.prefix(8))
        if paths.count > 8 {
            lines.append(APCLocalization.format(
                .connectionsMoreLocationsFormat,
                locale: locale,
                paths.count - 8
            ))
        }
        lines.append(APCLocalization.text(.connectionsSafetySummary, locale: locale))
        return lines.joined(separator: "\n")
    }

    static func operationFailureDetail(
        _ reason: AgentConnectionOperationFailureReason,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch reason {
        case .transportUnavailable: .connectionsFailureTransport
        case .rejected: .connectionsFailureRejected
        case .partialFailure: .connectionsFailurePartial
        case .invalidResponse: .connectionsFailureInvalidResponse
        case .invalidRequest: .connectionsFailureInvalidRequest
        case .unknown: .connectionsFailureUnknown
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func healthSummary(
        for presentation: AgentConnectionProductPresentation,
        operationState: AgentConnectionOperationState,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        if case let .failed(failure) = operationState,
           failure.operation.sources.contains(presentation.source) {
            return operationFailureDetail(failure.reason, locale: locale)
        }

        if presentation.health == .notChecked,
           presentation.hasCurrentLightSnapshot {
            return APCLocalization.text(
                .connectionsSummaryLight,
                locale: locale
            )
        }

        if let reason = attentionReason(for: presentation) {
            return attentionSummary(
                reason,
                source: presentation.source,
                locale: locale
            )
        }

        if presentation.health == .connected,
           presentation.taskVerification == .awaitingTask {
            return taskVerificationDetail(
                presentation.taskVerification,
                locale: locale
            )
        }

        let key: APCLocalizationKey = switch presentation.health {
        case .notChecked: .connectionsSummaryNotChecked
        case .checking: .connectionsSummaryChecking
        case .connected: .connectionsSummaryConnected
        case .needsRepair: .connectionsSummaryNeedsRepair
        case .unavailable: .connectionsSummaryUnavailable
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func healthTitle(
        for presentation: AgentConnectionProductPresentation,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        if presentation.health == .notChecked,
           presentation.hasCurrentLightSnapshot {
            return APCLocalization.text(
                .connectionsHealthLight,
                locale: locale
            )
        }
        guard let reason = attentionReason(for: presentation) else {
            if presentation.health == .connected,
               presentation.taskVerification == .awaitingTask {
                return APCLocalization.text(
                    .connectionsHealthUnverified,
                    locale: locale
                )
            }
            return APCLocalizedPresentation.connectionHealthTitle(
                presentation.health,
                locale: locale
            )
        }

        let key: APCLocalizationKey = switch reason {
        case .managedRepair: .productConnectionNeedsRepair
        case .agentMissing: .connectionsStatusAgentMissing
        case .updateRequired: .connectionsStatusUpdateRequired
        case .hookAuthorization: .connectionsStatusHookAuthorization
        case .permissionRequired: .connectionsStatusPermissionRequired
        case .restartRequired: .connectionsStatusRestartRequired
        case .localConnectionIssue: .connectionsStatusLocalIssue
        case .actionRequired: .connectionsStatusActionRequired
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func healthAppearance(
        for presentation: AgentConnectionProductPresentation
    ) -> ProductStatusAppearance {
        if presentation.health == .connected,
           presentation.taskVerification == .awaitingTask {
            return .neutral
        }
        return ProductStatusAppearance(connectionHealth: presentation.health)
    }

    static func userGuidance(
        for presentation: AgentConnectionProductPresentation,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String? {
        guard let reason = attentionReason(for: presentation) else {
            return nil
        }

        switch reason {
        case .managedRepair:
            return APCLocalization.text(
                .connectionsGuidanceRepair,
                locale: locale
            )
        case .agentMissing:
            return APCLocalization.format(
                .connectionsGuidanceInstallFormat,
                locale: locale,
                presentation.source.title
            )
        case .updateRequired:
            return APCLocalization.format(
                .connectionsGuidanceUpdateFormat,
                locale: locale,
                presentation.source.title
            )
        case .hookAuthorization:
            return APCLocalization.text(
                .connectionsGuidanceHookAuthorization,
                locale: locale
            )
        case .permissionRequired:
            return APCLocalization.text(
                .connectionsGuidanceSettings,
                locale: locale
            )
        case .restartRequired:
            return APCLocalization.format(
                .connectionsGuidanceFullRestartFormat,
                locale: locale,
                presentation.source.title
            )
        case .localConnectionIssue:
            return APCLocalization.text(
                .connectionsGuidanceLocalService,
                locale: locale
            )
        case .actionRequired:
            return APCLocalization.text(
                .connectionsGuidanceActionRequired,
                locale: locale
            )
        }
    }

    static func attentionReason(
        for presentation: AgentConnectionProductPresentation
    ) -> AgentConnectionAttentionReason? {
        if presentation.health == .needsRepair {
            return .managedRepair
        }
        guard presentation.health == .unavailable else { return nil }

        let items = presentation.technicalItems
        if presentation.source == .codex,
           items.contains(where: { item in
               guard item.status.isBlocking else { return false }
               if case .codexHookTrust = item.evidence {
                   return true
               }
               return false
           }) {
            return .hookAuthorization
        }
        if items.contains(where: {
            $0.code == .agentCLI
                && ($0.status == .missing || $0.status == .unsupported)
        }) {
            return .agentMissing
        }
        if items.contains(where: {
            $0.code == .claudeHooksPolicy && $0.status.isBlocking
        }) {
            return .permissionRequired
        }
        if items.contains(where: {
            switch $0.code {
            case .eventCLI, .eventDelivery, .channelTest:
                $0.status.isBlocking
            default:
                false
            }
        }) {
            return .localConnectionIssue
        }
        if items.contains(where: {
            switch $0.code {
            case .hostRuntime, .hostVerification, .appServer, .hostServer:
                $0.status.isBlocking
            default:
                false
            }
        }) {
            return .restartRequired
        }
        return .actionRequired
    }

    private static func attentionSummary(
        _ reason: AgentConnectionAttentionReason,
        source: AgentSource,
        locale: String
    ) -> String {
        switch reason {
        case .managedRepair:
            return APCLocalization.text(
                .connectionsSummaryNeedsRepair,
                locale: locale
            )
        case .agentMissing:
            return APCLocalization.format(
                .connectionsSummaryAgentMissingFormat,
                locale: locale,
                source.title
            )
        case .updateRequired:
            return APCLocalization.format(
                .connectionsSummaryUpdateRequiredFormat,
                locale: locale,
                source.title
            )
        case .hookAuthorization:
            return APCLocalization.text(
                .connectionsSummaryHookAuthorization,
                locale: locale
            )
        case .permissionRequired:
            return APCLocalization.format(
                .connectionsSummaryPermissionRequiredFormat,
                locale: locale,
                source.title
            )
        case .restartRequired:
            return APCLocalization.format(
                .connectionsSummaryRestartRequiredFormat,
                locale: locale,
                source.title
            )
        case .localConnectionIssue:
            return APCLocalization.text(
                .connectionsSummaryLocalIssue,
                locale: locale
            )
        case .actionRequired:
            return APCLocalization.text(
                .connectionsSummaryActionRequired,
                locale: locale
            )
        }
    }

    static func taskVerificationTitle(
        _ state: AgentTaskVerificationState,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch state {
        case .notRun: .connectionsVerificationNotRunTitle
        case .awaitingTask: .connectionsVerificationPendingTitle
        case .verified: .connectionsVerificationVerifiedTitle
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func taskVerificationDetail(
        _ state: AgentTaskVerificationState,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch state {
        case .notRun: .connectionsVerificationNotRunDetail
        case .awaitingTask: .connectionsVerificationPendingDetail
        case .verified: .connectionsVerificationVerifiedDetail
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func primaryActionPresentation(
        for presentation: AgentConnectionProductPresentation,
        busy: Bool,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> ProductActionPresentation<AgentConnectionPrimaryAction>? {
        let action = presentation.primaryAction
        let title: String
        if action == .verify {
            title = APCLocalization.text(.connectionsRecheck, locale: locale)
        } else if let localizedTitle = APCLocalizedPresentation.primaryActionTitle(
            action,
            locale: locale
        ) {
            title = localizedTitle
        } else {
            return nil
        }

        let image: String
        let hintKey: APCLocalizationKey
        switch action {
        case .connect:
            image = "link.badge.plus"
            hintKey = .connectionsPrimaryConnectHint
        case .repair:
            image = "wrench.and.screwdriver"
            hintKey = .connectionsPrimaryRepairHint
        case .verify:
            image = "arrow.clockwise"
            hintKey = attentionReason(for: presentation) == nil
                ? .connectionsPrimaryVerifyHint
                : .connectionsPrimaryAttentionVerifyHint
        case .retry:
            image = "arrow.clockwise"
            hintKey = .connectionsPrimaryRetryHint
        case .unavailable:
            return nil
        }

        return ProductActionPresentation(
            action: action,
            title: title,
            systemImage: image,
            accessibilityLabel: APCLocalization.format(
                .connectionsPrimaryAccessibilityFormat,
                locale: locale,
                title,
                presentation.source.title
            ),
            accessibilityHint: APCLocalization.text(
                busy ? .connectionsBusyHint : hintKey,
                locale: locale
            ),
            isEnabled: !busy
        )
    }

    static func actionLayout(
        for presentation: AgentConnectionProductPresentation
    ) -> AgentConnectionActionLayout {
        let primaryAction: AgentConnectionPrimaryAction? =
            switch presentation.primaryAction {
        case .connect, .repair, .retry:
            presentation.primaryAction
        case .verify:
            presentation.health == .connected ? nil : .verify
        case .unavailable:
            nil
        }

        var moreActions: [AgentConnectionMoreAction] = []
        if primaryAction != .verify {
            moreActions.append(.recheck)
        }
        moreActions.append(.sendTestMessage)
        if presentation.canManageManagedConnector,
           primaryAction != .connect,
           primaryAction != .repair {
            moreActions.append(.setUpAgain)
        }
        if presentation.canUninstall {
            moreActions.append(.remove)
        }

        return AgentConnectionActionLayout(
            primaryAction: primaryAction,
            moreActions: moreActions
        )
    }

    static func itemDisplayName(
        for item: AgentConnectionTechnicalItem,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch item.code {
        case .agentCLI: .connectionsCheckNameAgentCLI
        case .eventCLI: .connectionsCheckNameEventCLI
        case .projectDirectory, .unknown: .connectionsCheckNameGeneric
        case .agentVersion: .connectionsCheckNameAgentVersion
        case .managedConnector: .connectionsCheckNameManagedConnector
        case .claudeHooksPolicy: .connectionsCheckNameClaudeHooksPolicy
        case .hostRuntime, .hostVerification: .connectionsCheckNameHostVerification
        case .eventDelivery: .connectionsCheckNameEventDelivery
        case .channelTest: .connectionsCheckNameChannelTest
        case .appServer: .connectionsCheckNameAppServer
        case .hostServer: .connectionsCheckNameHostServer
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func itemDisplayDetail(
        for item: AgentConnectionTechnicalItem,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch item.code {
        case .agentCLI: .connectionsCheckDescriptionAgentCLI
        case .eventCLI: .connectionsCheckDescriptionEventCLI
        case .projectDirectory, .unknown: .connectionsCheckDescriptionGeneric
        case .agentVersion: .connectionsCheckDescriptionAgentVersion
        case .managedConnector: .connectionsCheckDescriptionManagedConnector
        case .claudeHooksPolicy: .connectionsCheckDescriptionClaudeHooksPolicy
        case .hostRuntime, .hostVerification: .connectionsCheckDescriptionHostVerification
        case .eventDelivery: .connectionsCheckDescriptionEventDelivery
        case .channelTest: .connectionsCheckDescriptionChannelTest
        case .appServer: .connectionsCheckDescriptionAppServer
        case .hostServer: .connectionsCheckDescriptionHostServer
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func itemTone(
        for item: AgentConnectionTechnicalItem
    ) -> AgentConnectionVisualTone {
        switch item.status {
        case .ok: .good
        case .needsFix: .warning
        case .missing: .destructive
        case .unverified, .unsupported, .notRequired: .neutral
        }
    }

    static func itemSystemImage(
        for item: AgentConnectionTechnicalItem
    ) -> String {
        switch item.status {
        case .ok: "checkmark.circle.fill"
        case .needsFix: "wrench.and.screwdriver.fill"
        case .missing: "xmark.circle.fill"
        case .unverified: "questionmark.circle.fill"
        case .unsupported: "minus.circle.fill"
        case .notRequired: "circle.dashed"
        }
    }

    static func itemStatusTitle(
        for item: AgentConnectionTechnicalItem,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        APCLocalizedPresentation.checkStatusTitle(item.status, locale: locale)
    }

    static func itemEvidenceDetail(
        for item: AgentConnectionTechnicalItem,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String? {
        switch item.evidence {
        case let .agentVersion(source, detected):
            guard let detected else {
                return APCLocalization.format(
                    .connectionsEvidenceVersionMissingFormat,
                    locale: locale,
                    source.title
                )
            }
            return APCLocalization.format(
                .connectionsEvidenceVersionSupportedFormat,
                locale: locale,
                detected,
                source.title
            )
        case let .codexHookTrust(disabled, modified, untrusted, total):
            return APCLocalization.format(
                .connectionsEvidenceCodexTrustFormat,
                locale: locale,
                disabled,
                modified,
                untrusted,
                total
            )
        case nil:
            return nil
        }
    }

    static func extensionKindTitle(
        _ kind: AgentExtensionKind,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch kind {
        case .connector: .connectionsComponentKindConnector
        case .plugin: .connectionsComponentKindPlugin
        case .hostExtension: .connectionsComponentKindExtension
        case .package: .connectionsComponentKindPackage
        case .skill: .connectionsComponentKindSkill
        case .unknown: .connectionsComponentKindUnknown
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func managedComponentStatusTitle(
        _ component: AgentManagedComponent,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        if managedComponentHasVersionMismatch(component) {
            return APCLocalization.text(
                .connectionsComponentVersionMismatch,
                locale: locale
            )
        }

        let statusTitle = APCLocalizedPresentation.checkStatusTitle(
            component.status,
            locale: locale
        )
        guard let activeVersion = component.activeVersion,
              let displayedVersion =
                displayedManagedComponentVersion(activeVersion) else {
            return statusTitle
        }
        return "\(displayedVersion) · \(statusTitle)"
    }

    static func managedComponentHasVersionMismatch(
        _ component: AgentManagedComponent
    ) -> Bool {
        guard let expectedVersion = component.expectedVersion,
              let activeVersion = component.activeVersion,
              let normalizedExpectedVersion =
                normalizedManagedComponentVersion(expectedVersion),
              let normalizedActiveVersion =
                normalizedManagedComponentVersion(activeVersion) else {
            return false
        }
        return normalizedExpectedVersion != normalizedActiveVersion
    }

    static func managedComponentVersionDetail(
        _ component: AgentManagedComponent,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String? {
        if let expectedVersion = component.expectedVersion,
           let activeVersion = component.activeVersion,
           managedComponentHasVersionMismatch(component),
           let displayedActiveVersion =
               displayedManagedComponentVersion(activeVersion),
           let displayedExpectedVersion =
               displayedManagedComponentVersion(expectedVersion) {
            return APCLocalization.format(
                .connectionsComponentVersionMismatchDetailFormat,
                locale: locale,
                displayedActiveVersion,
                displayedExpectedVersion
            )
        }

        guard component.activeVersion == nil,
              let expectedVersion = component.expectedVersion,
              let displayedExpectedVersion =
                displayedManagedComponentVersion(expectedVersion) else {
            return nil
        }
        return APCLocalization.format(
            .connectionsComponentRequiredVersionFormat,
            locale: locale,
            displayedExpectedVersion
        )
    }

    private static func displayedManagedComponentVersion(
        _ version: String
    ) -> String? {
        normalizedManagedComponentVersion(version).map { "v\($0)" }
    }

    private static func normalizedManagedComponentVersion(
        _ version: String
    ) -> String? {
        guard let firstCharacter = version.first else {
            return nil
        }
        if firstCharacter.isNumber {
            return version
        }
        if firstCharacter.lowercased() == "v",
           version.dropFirst().first?.isNumber == true {
            return String(version.dropFirst())
        }
        return nil
    }

    static func verificationTitle(
        _ status: AgentVerificationStatus,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch status {
        case .verified: .connectionsVerificationVerifiedTitle
        case .actionRequired: .connectionsVerificationActionTitle
        case .unverified: .connectionsVerificationPendingTitle
        case .notRequired: .connectionsVerificationNotRequiredTitle
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func verificationDetail(
        _ status: AgentVerificationStatus,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch status {
        case .verified: .connectionsVerificationVerifiedDetail
        case .actionRequired: .connectionsVerificationActionDetail
        case .unverified: .connectionsVerificationPendingDetail
        case .notRequired: .connectionsVerificationNotRequiredDetail
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func failure(
        for source: AgentSource,
        in operationState: AgentConnectionOperationState
    ) -> AgentConnectionOperationFailure? {
        guard case let .failed(failure) = operationState,
              failure.operation.sources.contains(source) else {
            return nil
        }
        return failure
    }

    static func success(
        for source: AgentSource,
        in operationState: AgentConnectionOperationState
    ) -> AgentConnectionOperation? {
        guard let operation = operationState.succeededOperation,
              operation.sources == [source] else {
            return nil
        }
        return operation
    }

    static func success(
        for source: AgentSource,
        in operationState: AgentConnectionOperationState,
        status: AgentConnectionStatus?
    ) -> AgentConnectionOperation? {
        guard let operation = success(for: source, in: operationState) else {
            return nil
        }
        if operation.kind == .repair,
           status?.blockingItems.isEmpty != true {
            return nil
        }
        return operation
    }

    static func operationSuccessDetail(
        _ operation: AgentConnectionOperation,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch operation.kind {
        case .check: .connectionsSuccessCheck
        case .test: .connectionsSuccessTest
        case .repair: .connectionsSuccessRepair
        case .uninstall: .connectionsSuccessUninstall
        }
        return APCLocalization.text(key, locale: locale)
    }
}

struct AgentConnectionsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirmingRepairAll = false
    @State private var expandedSource: AgentSource?

    var body: some View {
        ScrollView {
            LazyVStack(
                alignment: .leading,
                spacing: SharedProductComponentLayout.pageSpacing
            ) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        pageHeader
                        Spacer(minLength: 12)
                        pageActions
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        pageHeader
                        pageActions
                    }
                }

                ForEach(AgentConnectionsCatalog.sources) { source in
                    AgentConnectionSection(
                        source: source,
                        status: store.connections.first { $0.source == source },
                        isExpanded: expandedSource == source,
                        onToggle: {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                expandedSource = expandedSource == source
                                    ? nil
                                    : source
                            }
                        }
                    )
                }
            }
            .frame(
                minWidth: SharedProductComponentLayout.supportedMinimumContentWidth,
                maxWidth: .infinity,
                alignment: .topLeading
            )
            .padding(24)
        }
        .accessibilityIdentifier("connections.root")
        .confirmationDialog(
            APCLocalization.text(.connectionsConfirmRepairAll),
            isPresented: $confirmingRepairAll,
            titleVisibility: .visible
        ) {
            Button(APCLocalization.format(
                .connectionsRepairCountFormat,
                manageableSources.count
            )) {
                let sources = manageableSources
                guard !sources.isEmpty, store.canStartConnectionOperation else {
                    return
                }
                store.repairConnections(sources)
            }
            Button(APCLocalization.text(.commonCancel), role: .cancel) {}
        } message: {
            Text(AgentConnectionsPresentation.managedRepairConfirmationMessage(
                for: manageableStatuses
            ))
        }
        .onAppear {
            store.requestAutomaticConnectionCheckOnFirstPresentation()
            revealFirstUpdateAttentionSource()
        }
        .onChange(of: store.appUpdateConvergenceState) { _, _ in
            revealFirstUpdateAttentionSource()
        }
    }

    private var pageHeader: some View {
        ProductPageHeader(
            identity: ProductComponentIdentity(scope: "connections"),
            title: APCLocalization.text(.connectionsPageTitle),
            summary: APCLocalization.text(.connectionsPageSubtitle)
        )
    }

    @ViewBuilder
    private var pageActions: some View {
        if manageableSources.isEmpty {
            checkAllButton
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    repairAllButton
                    checkAllButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    repairAllButton
                    checkAllButton
                }
            }
        }
    }

    private var repairAllButton: some View {
        Button {
            confirmingRepairAll = true
        } label: {
            Label(
                APCLocalization.text(.connectionsRepairAll),
                systemImage: "wand.and.stars"
            )
        }
        .apcClearGlassButtonStyle()
        .controlSize(.regular)
        .disabled(!store.canStartConnectionOperation)
        .accessibilityHint(APCLocalization.text(
            store.canStartConnectionOperation
                ? .connectionsPrimaryRepairHint
                : .connectionsBusyHint
        ))
        .accessibilityIdentifier("connections.secondary.setup-all")
    }

    private var checkAllButton: some View {
        Button {
            store.checkAllConnections()
        } label: {
            Label(
                APCLocalization.text(.connectionsCheckAll),
                systemImage: "checkmark.circle"
            )
        }
        .apcClearGlassButtonStyle(prominent: true)
        .controlSize(.regular)
        .disabled(!store.canStartConnectionOperation)
        .accessibilityHint(APCLocalization.text(
            store.canStartConnectionOperation
                ? .connectionsCheckAllHint
                : .connectionsBusyHint
        ))
        .accessibilityIdentifier("connections.primary.check-all")
    }

    private var manageableStatuses: [AgentConnectionStatus] {
        AgentConnectionsPresentation.manageableStatuses(
            from: store.connections
        )
    }

    private var manageableSources: [AgentSource] {
        manageableStatuses.map(\.source)
    }

    private func revealFirstUpdateAttentionSource() {
        guard case let .needsAttention(.connectors(issues)) =
                store.appUpdateConvergenceState,
              let source = issues.first?.source
        else { return }
        expandedSource = source
    }
}

private struct AgentConnectionSection: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirmingRepair = false
    @State private var confirmingUninstall = false

    let source: AgentSource
    let status: AgentConnectionStatus?
    let isExpanded: Bool
    let onToggle: () -> Void

    private var presentation: AgentConnectionProductPresentation {
        AgentConnectionProductPresentation(
            source: source,
            status: status,
            operationState: store.connectionOperationState
        )
    }

    private var busy: Bool {
        !store.canStartConnectionOperation
    }

    var body: some View {
        ProductCardSurface(padding: SharedProductComponentLayout.compactPadding) {
            VStack(alignment: .leading, spacing: 0) {
                disclosureButton

                if isExpanded {
                    Divider()
                        .padding(.top, 12)

                    connectionDetails
                        .padding(.top, 14)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .confirmationDialog(
            APCLocalization.format(.connectionsConfirmRepairFormat, source.title),
            isPresented: $confirmingRepair,
            titleVisibility: .visible
        ) {
            Button(APCLocalization.text(.connectionsWriteRepair)) {
                let current = AgentConnectionProductPresentation(
                    source: source,
                    status: status,
                    operationState: store.connectionOperationState
                )
                guard current.canManageManagedConnector else {
                    return
                }
                store.repairConnection(source)
            }
            Button(APCLocalization.text(.commonCancel), role: .cancel) {}
        } message: {
            Text(repairConfirmationMessage)
        }
        .confirmationDialog(
            APCLocalization.format(.connectionsConfirmUninstallFormat, source.title),
            isPresented: $confirmingUninstall,
            titleVisibility: .visible
        ) {
            Button(
                APCLocalization.text(.connectionsUninstall),
                role: .destructive
            ) {
                guard status?.canUninstallManagedConnector == true else { return }
                store.uninstallConnection(source)
            }
            Button(APCLocalization.text(.commonCancel), role: .cancel) {}
        } message: {
            Text(uninstallConfirmationMessage)
        }
        .accessibilityIdentifier("connections.agent-section.\(source.rawValue)")
    }

    private var disclosureButton: some View {
        Button(action: onToggle) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    agentIdentity
                    Spacer(minLength: 12)
                    healthIndicator
                    disclosureChevron
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        agentIdentity
                        Spacer(minLength: 8)
                        disclosureChevron
                    }
                    healthIndicator
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(source.title)
        .accessibilityValue(APCLocalization.format(
            .connectionsMetadataFormat,
            healthTitle,
            APCLocalization.text(
                isExpanded ? .commonExpanded : .commonCollapsed
            )
        ))
        .accessibilityHint(APCLocalization.text(
            isExpanded
                ? .commonCollapseDisclosureHint
                : .commonExpandDisclosureHint
        ))
        .accessibilityIdentifier(
            "connections.agent-toggle.\(source.rawValue)"
        )
    }

    private var agentIdentity: some View {
        HStack(alignment: .center, spacing: 12) {
            AgentIconView(source: source, size: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(source.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                Text(AgentConnectionsPresentation.healthSummary(
                    for: presentation,
                    operationState: store.connectionOperationState
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var healthTitle: String {
        AgentConnectionsPresentation.healthTitle(for: presentation)
    }

    private var healthIndicator: some View {
        ProductStatusIndicator(
            presentation: ProductStatusPresentation(
                appearance: AgentConnectionsPresentation.healthAppearance(
                    for: presentation
                ),
                title: healthTitle
            )
        )
    }

    private var disclosureChevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 18, height: 22)
            .accessibilityHidden(true)
    }

    private var connectionDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let runningOperationTitle {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(runningOperationTitle)
                        .font(.callout.weight(.semibold))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(
                    "connections.operation.running.\(source.rawValue)"
                )
            }

            if let failure = AgentConnectionsPresentation.failure(
                for: source,
                in: store.connectionOperationState
            ) {
                operationFailureNotice(failure)
            }

            if let success = AgentConnectionsPresentation.success(
                for: source,
                in: store.connectionOperationState,
                status: status
            ) {
                operationSuccessNotice(success)
            }

            connectionOverview

            if !presentation.managedComponents.isEmpty {
                managedComponents
            }

            actionControls
        }
    }

    private var connectionOverview: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: overviewSystemImage)
                .foregroundStyle(overviewColor)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(overviewTitle)
                .font(.callout.weight(.semibold))

                Text(overviewDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            "connections.agent-verification.\(source.rawValue)"
        )
    }

    private var overviewSystemImage: String {
        AgentConnectionsPresentation.attentionReason(for: presentation) == nil
            ? presentation.taskVerification.systemImage
            : "exclamationmark.triangle.fill"
    }

    private var overviewColor: Color {
        AgentConnectionsPresentation.attentionReason(for: presentation) == nil
            ? presentation.taskVerification.color
            : APCDesign.warning
    }

    private var overviewTitle: String {
        if AgentConnectionsPresentation.attentionReason(for: presentation) != nil {
            return healthTitle
        }
        return AgentConnectionsPresentation.taskVerificationTitle(
            presentation.taskVerification
        )
    }

    private var overviewDetail: String {
        if let guidance = AgentConnectionsPresentation.userGuidance(
            for: presentation
        ) {
            return guidance
        }
        return AgentConnectionsPresentation.taskVerificationDetail(
            presentation.taskVerification
        )
    }

    private var managedComponents: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(APCLocalization.text(.connectionsManagedComponentsTitle))
                    .font(.callout.weight(.semibold))

                Text(APCLocalization.text(.connectionsManagedComponentsSummary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(
                    Array(presentation.managedComponents.enumerated()),
                    id: \.offset
                ) { index, component in
                    AgentManagedComponentRow(component: component)
                    if index < presentation.managedComponents.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .padding(12)
        .background(
            Color.secondary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityIdentifier(
            "connections.managed-components.\(source.rawValue)"
        )
    }

    private var featuredAction:
        ProductActionPresentation<AgentConnectionPrimaryAction>? {
        guard actionLayout.primaryAction == presentation.primaryAction else {
            return nil
        }
        return AgentConnectionsPresentation.primaryActionPresentation(
            for: presentation,
            busy: busy
        )
    }

    private var actionLayout: AgentConnectionActionLayout {
        AgentConnectionsPresentation.actionLayout(for: presentation)
    }

    private func performPrimaryAction(
        _ action: AgentConnectionPrimaryAction
    ) {
        switch action {
        case .connect, .repair:
            guard presentation.canRepairManagedConnector,
                  presentation.primaryAction == action else {
                return
            }
            confirmingRepair = true
        case .verify:
            guard !busy else { return }
            store.checkConnection(source)
        case .retry:
            guard AgentConnectionsPresentation.failure(
                for: source,
                in: store.connectionOperationState
            ) != nil else {
                return
            }
            store.retryConnectionOperation()
        case .unavailable:
            break
        }
    }

    private var runningOperationTitle: String? {
        guard let operation = store.connectionOperationState.runningOperation,
              operation.sources.contains(source) else {
            return nil
        }
        let key: APCLocalizationKey = switch operation.kind {
        case .check: .connectionsOperationCheck
        case .test: .connectionsOperationTest
        case .repair: .connectionsOperationRepair
        case .uninstall: .connectionsOperationUninstall
        }
        return APCLocalization.format(
            .connectionsOperationTitleFormat,
            source.title,
            APCLocalization.text(key)
        )
    }

    private func operationFailureNotice(
        _ failure: AgentConnectionOperationFailure
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(APCDesign.destructive)
                .accessibilityHidden(true)

            Text(
                AgentConnectionsPresentation.operationFailureDetail(
                    failure.reason
                )
            )
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            Button(APCLocalization.text(.connectionsOperationDismiss)) {
                store.dismissConnectionOperationNotice()
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(
                "connections.operation.dismiss.\(source.rawValue)"
            )
        }
        .padding(12)
        .background(
            APCDesign.destructive.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(APCDesign.destructive.opacity(0.38), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "connections.operation.failure.\(source.rawValue)"
        )
    }

    private func operationSuccessNotice(
        _ operation: AgentConnectionOperation
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(APCDesign.success)
                .accessibilityHidden(true)

            Text(AgentConnectionsPresentation.operationSuccessDetail(operation))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            Button(APCLocalization.text(.connectionsOperationDismiss)) {
                store.dismissConnectionOperationNotice()
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(
                "connections.operation.success.dismiss.\(source.rawValue)"
            )
        }
        .padding(12)
        .background(
            APCDesign.success.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(APCDesign.success.opacity(0.38), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "connections.operation.success.\(source.rawValue)"
        )
    }

    private var actionControls: some View {
        HStack(spacing: 10) {
            if let featuredAction {
                Button {
                    performPrimaryAction(featuredAction.action)
                } label: {
                    Label(
                        featuredAction.title,
                        systemImage: featuredAction.systemImage
                            ?? "arrow.right.circle"
                    )
                }
                .apcClearGlassButtonStyle()
                .disabled(!featuredAction.isEnabled)
                .accessibilityLabel(featuredAction.accessibilityLabel)
                .accessibilityHint(featuredAction.accessibilityHint ?? "")
                .accessibilityIdentifier(
                    "connections.primary.\(source.rawValue)"
                )
            }

            moreActionsMenu
        }
    }

    private var moreActionsMenu: some View {
        Menu {
            if actionLayout.moreActions.contains(.recheck) {
                Button {
                    store.checkConnection(source)
                } label: {
                    Label(
                        APCLocalization.text(.connectionsRecheck),
                        systemImage: "arrow.clockwise"
                    )
                }
                .accessibilityHint(APCLocalization.text(
                    busy ? .connectionsBusyHint : .connectionsRecheckHint
                ))
                .accessibilityIdentifier(
                    "connections.secondary.recheck.\(source.rawValue)"
                )
            }

            if actionLayout.moreActions.contains(.sendTestMessage) {
                Button {
                    store.sendConnectionTestEvent(source)
                } label: {
                    Label(
                        APCLocalization.text(.connectionsTestChannel),
                        systemImage: "wave.3.right"
                    )
                }
                .accessibilityHint(APCLocalization.text(
                    busy ? .connectionsBusyHint : .connectionsTestHint
                ))
                .accessibilityIdentifier(
                    "connections.secondary.test-channel.\(source.rawValue)"
                )
            }

            if actionLayout.moreActions.contains(.setUpAgain) {
                Divider()

                Button {
                    confirmingRepair = true
                } label: {
                    Label(
                        APCLocalization.text(.connectionsSetUpAgain),
                        systemImage: "wrench.and.screwdriver"
                    )
                }
                .accessibilityHint(APCLocalization.text(
                    busy ? .connectionsBusyHint : .connectionsRepairAgainHint
                ))
                .accessibilityIdentifier(
                    "connections.secondary.install-repair.\(source.rawValue)"
                )
            }

            if actionLayout.moreActions.contains(.remove) {
                Divider()

                Button(role: .destructive) {
                    confirmingUninstall = true
                } label: {
                    Label(
                        APCLocalization.text(.connectionsUninstall),
                        systemImage: "trash"
                    )
                }
                .accessibilityHint(APCLocalization.text(.connectionsUninstallHint))
                .accessibilityIdentifier(
                    "connections.secondary.uninstall.\(source.rawValue)"
                )
            }
        } label: {
            Label(
                APCLocalization.text(.appActionMore),
                systemImage: "ellipsis.circle"
            )
        }
        .disabled(busy)
        .accessibilityIdentifier(
            "connections.secondary.more.\(source.rawValue)"
        )
    }

    private var repairConfirmationMessage: String {
        guard presentation.canManageManagedConnector else {
            return APCLocalization.text(.connectionsRepairUnavailable)
        }
        var lines = [APCLocalization.text(.connectionsRepairFilesIntro)]
        if let status, !status.installPaths.isEmpty {
            lines.append(contentsOf: status.installPaths.prefix(8))
            if status.installPaths.count > 8 {
                lines.append(APCLocalization.format(
                    .connectionsMoreLocationsFormat,
                    status.installPaths.count - 8
                ))
            }
        } else {
            lines.append(APCLocalization.text(.connectionsPathsUnreported))
        }
        lines.append(APCLocalization.text(.connectionsRepairSafety))
        return lines.joined(separator: "\n")
    }

    private var uninstallConfirmationMessage: String {
        guard let status, status.canUninstallManagedConnector else {
            return APCLocalization.text(.connectionsUninstallUnavailable)
        }
        var lines = [APCLocalization.text(.connectionsUninstallFilesIntro)]
        if status.installPaths.isEmpty {
            lines.append(APCLocalization.text(.connectionsPathsUnreported))
        } else {
            lines.append(contentsOf: status.installPaths.prefix(8))
            if status.installPaths.count > 8 {
                lines.append(APCLocalization.format(
                    .connectionsMoreLocationsFormat,
                    status.installPaths.count - 8
                ))
            }
        }
        lines.append(APCLocalization.text(.connectionsSafetySummary))
        return lines.joined(separator: "\n")
    }
}

private struct AgentManagedComponentRow: View {
    let component: AgentManagedComponent

    private var hasVersionMismatch: Bool {
        AgentConnectionsPresentation.managedComponentHasVersionMismatch(
            component
        )
    }

    private var componentSystemImage: String {
        switch component.kind {
        case .connector: "cable.connector"
        case .plugin: "puzzlepiece.extension"
        case .hostExtension: "bolt.horizontal.circle"
        case .package: "shippingbox"
        case .skill: "sparkles.rectangle.stack"
        case .unknown: "questionmark.square.dashed"
        }
    }

    private var statusSystemImage: String {
        if hasVersionMismatch {
            return "exclamationmark.triangle.fill"
        }
        return switch component.status {
        case .ok: "checkmark.circle.fill"
        case .needsFix: "wrench.and.screwdriver.fill"
        case .missing: "xmark.circle.fill"
        case .unverified: "questionmark.circle.fill"
        case .unsupported: "minus.circle.fill"
        case .notRequired: "circle.dashed"
        }
    }

    private var statusColor: Color {
        if hasVersionMismatch {
            return APCDesign.warning
        }
        return switch component.status {
        case .ok: APCDesign.success
        case .needsFix: APCDesign.warning
        case .missing: APCDesign.destructive
        case .unverified, .unsupported, .notRequired:
            APCDesign.textSecondary
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: componentSystemImage)
                .foregroundStyle(APCDesign.accent)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(component.name)
                    .font(.callout.weight(.medium))

                Text(AgentConnectionsPresentation.extensionKindTitle(
                    component.kind
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Label(
                    AgentConnectionsPresentation.managedComponentStatusTitle(
                        component
                    ),
                    systemImage: statusSystemImage
                )
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)

                if let versionDetail =
                    AgentConnectionsPresentation.managedComponentVersionDetail(
                        component
                    )
                {
                    Text(versionDetail)
                        .font(.caption2)
                        .foregroundStyle(
                            hasVersionMismatch
                                ? APCDesign.warning
                                : APCDesign.textSecondary
                        )
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}
