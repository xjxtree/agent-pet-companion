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

        let key: APCLocalizationKey = switch presentation.health {
        case .notChecked: .connectionsSummaryNotChecked
        case .checking: .connectionsSummaryChecking
        case .connected: .connectionsSummaryConnected
        case .needsRepair: .connectionsSummaryNeedsRepair
        case .unavailable: .connectionsSummaryUnavailable
        }
        return APCLocalization.text(key, locale: locale)
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
        guard let title = APCLocalizedPresentation.primaryActionTitle(
            action,
            locale: locale
        ) else {
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
            image = "checkmark.seal"
            hintKey = .connectionsPrimaryVerifyHint
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
            let support = versionSupportDescription(
                for: source,
                locale: locale
            )
            guard let detected else {
                return APCLocalization.format(
                    .connectionsEvidenceVersionMissingFormat,
                    locale: locale,
                    support
                )
            }
            switch item.status {
            case .ok:
                return APCLocalization.format(
                    .connectionsEvidenceVersionSupportedFormat,
                    locale: locale,
                    detected,
                    support
                )
            case .missing, .needsFix:
                return APCLocalization.format(
                    .connectionsEvidenceVersionUpdateFormat,
                    locale: locale,
                    detected,
                    support,
                    source.title
                )
            case .unverified, .unsupported, .notRequired:
                return APCLocalization.format(
                    .connectionsEvidenceVersionUnverifiedFormat,
                    locale: locale,
                    detected,
                    support
                )
            }
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

    private static func versionSupportDescription(
        for source: AgentSource,
        locale: String
    ) -> String {
        let key: APCLocalizationKey = switch source {
        case .codex: .connectionsVersionSupportCodex
        case .claudeCode: .connectionsVersionSupportClaude
        case .pi: .connectionsVersionSupportPi
        case .opencode: .connectionsVersionSupportOpencode
        }
        return APCLocalization.text(key, locale: locale)
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
                        status: store.connections.first { $0.source == source }
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
        .buttonStyle(.bordered)
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
        .buttonStyle(.borderedProminent)
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
}

private struct AgentConnectionSection: View {
    @EnvironmentObject private var store: AppStore
    @State private var technicalDetailsExpanded = false
    @State private var confirmingRepair = false
    @State private var confirmingUninstall = false

    let source: AgentSource
    let status: AgentConnectionStatus?

    private var identity: ProductComponentIdentity {
        ProductComponentIdentity(
            scope: "connections",
            instance: source.rawValue
        )
    }

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
        VStack(alignment: .leading, spacing: 10) {
            AgentHealthRow(
                identity: identity,
                agentTitle: source.title,
                agentSummary: AgentConnectionsPresentation.healthSummary(
                    for: presentation,
                    operationState: store.connectionOperationState
                ),
                health: presentation.health,
                healthTitle: APCLocalizedPresentation.connectionHealthTitle(
                    presentation.health
                ),
                taskVerification: presentation.taskVerification,
                taskVerificationTitle:
                    AgentConnectionsPresentation.taskVerificationTitle(
                        presentation.taskVerification
                    ),
                taskVerificationDetail:
                    AgentConnectionsPresentation.taskVerificationDetail(
                        presentation.taskVerification
                    ),
                primaryAction: rowPrimaryAction,
                onPrimaryAction: performPrimaryAction
            )

            if let failure = AgentConnectionsPresentation.failure(
                for: source,
                in: store.connectionOperationState
            ) {
                operationFailureNotice(failure)
            }

            if let success = AgentConnectionsPresentation.success(
                for: source,
                in: store.connectionOperationState
            ) {
                operationSuccessNotice(success)
            }

            AdvancedDetailsDisclosure(
                identity: identity,
                title: APCLocalization.text(.connectionsTechnicalTitle),
                summary: APCLocalization.text(.connectionsTechnicalSummary),
                isExpanded: $technicalDetailsExpanded
            ) {
                technicalDetails
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

    private var rowPrimaryAction:
        ProductActionPresentation<AgentConnectionPrimaryAction>? {
        if presentation.health == .unavailable,
           presentation.primaryAction == .verify {
            return ProductActionPresentation(
                action: .verify,
                title: APCLocalization.text(.connectionsTroubleshoot),
                systemImage: "wrench.adjustable",
                accessibilityLabel: APCLocalization.format(
                    .connectionsPrimaryAccessibilityFormat,
                    APCLocalization.text(.connectionsTroubleshoot),
                    source.title
                ),
                accessibilityHint: APCLocalization.text(
                    busy ? .connectionsBusyHint : .connectionsTroubleshootHint
                ),
                isEnabled: !busy
            )
        }
        return AgentConnectionsPresentation.primaryActionPresentation(
            for: presentation,
            busy: busy
        )
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
            if presentation.health == .unavailable {
                withAnimation(.easeInOut(duration: 0.16)) {
                    technicalDetailsExpanded = true
                }
            } else {
                store.checkConnection(source)
            }
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

    @ViewBuilder
    private var technicalDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(APCLocalization.text(.connectionsValidationBoundary))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if presentation.technicalItems.isEmpty {
                Text(APCLocalization.text(.connectionsChecksEmpty))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(
                        Array(presentation.technicalItems.enumerated()),
                        id: \.offset
                    ) { index, item in
                            ConnectionTechnicalRow(item: item, index: index)
                        if index < presentation.technicalItems.count - 1 {
                            Divider()
                        }
                    }
                }
            }

            if let status {
                Divider()

                ConnectionVerificationSummary(
                    source: source,
                    status: status.verification.status
                )

                if status.hasInstalledConnectorArtifacts
                    || !status.installPaths.isEmpty {
                    Divider()
                    Label(
                        APCLocalization.text(.connectionsManagedArtifactsTitle),
                        systemImage: "shippingbox"
                    )
                    .font(.callout.weight(.semibold))
                    Text(APCLocalization.format(
                        .connectionsManagedArtifactsCountFormat,
                        status.installPaths.count
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Divider()
                secondaryActions(status)
            }
        }
    }

    private func secondaryActions(
        _ status: AgentConnectionStatus
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(APCLocalization.text(.connectionsLocalChannelTitle))
                    .font(.callout.weight(.semibold))
                Text(APCLocalization.text(.connectionsLocalChannelDetail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    inspectionActionButtons
                }
                VStack(alignment: .leading, spacing: 8) {
                    inspectionActionButtons
                }
            }

            if presentation.canManageManagedConnector
                || status.canUninstallManagedConnector {
                Divider()

                VStack(alignment: .leading, spacing: 3) {
                    Text(APCLocalization.text(.connectionsManagedActionsTitle))
                        .font(.callout.weight(.semibold))
                    Text(APCLocalization.text(.connectionsManagedActionsDetail))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        managedActionButtons(status)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        managedActionButtons(status)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var inspectionActionButtons: some View {
        Button {
            store.checkConnection(source)
        } label: {
            Label(
                APCLocalization.text(.connectionsRecheck),
                systemImage: "arrow.clockwise"
            )
        }
        .buttonStyle(.bordered)
        .disabled(busy)
        .accessibilityHint(APCLocalization.text(
            busy ? .connectionsBusyHint : .connectionsRecheckHint
        ))
        .accessibilityIdentifier(
            "connections.secondary.recheck.\(source.rawValue)"
        )

        Button {
            store.sendConnectionTestEvent(source)
        } label: {
            Label(
                APCLocalization.text(.connectionsTestChannel),
                systemImage: "wave.3.right"
            )
        }
        .buttonStyle(.bordered)
        .disabled(busy)
        .accessibilityHint(APCLocalization.text(
            busy ? .connectionsBusyHint : .connectionsTestHint
        ))
        .accessibilityIdentifier(
            "connections.secondary.test-channel.\(source.rawValue)"
        )
    }

    @ViewBuilder
    private func managedActionButtons(
        _ status: AgentConnectionStatus
    ) -> some View {
        if presentation.canManageManagedConnector {
            Button {
                confirmingRepair = true
            } label: {
                Label(
                    APCLocalization.text(.connectionsInstallRepair),
                    systemImage: "wrench.and.screwdriver"
                )
            }
            .buttonStyle(.bordered)
            .disabled(busy)
            .accessibilityHint(APCLocalization.text(
                busy ? .connectionsBusyHint : .connectionsRepairAgainHint
            ))
            .accessibilityIdentifier(
                "connections.secondary.install-repair.\(source.rawValue)"
            )
        }

        if status.canUninstallManagedConnector {
            Button(role: .destructive) {
                confirmingUninstall = true
            } label: {
                Label(
                    APCLocalization.text(.connectionsUninstall),
                    systemImage: "trash"
                )
            }
            .buttonStyle(.bordered)
            .disabled(busy)
            .accessibilityHint(APCLocalization.text(.connectionsUninstallHint))
            .accessibilityIdentifier(
                "connections.secondary.uninstall.\(source.rawValue)"
            )
        }
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

private struct ConnectionTechnicalRow: View {
    let item: AgentConnectionTechnicalItem
    let index: Int

    private var tone: AgentConnectionVisualTone {
        AgentConnectionsPresentation.itemTone(for: item)
    }

    private var evidenceDetail: String? {
        AgentConnectionsPresentation.itemEvidenceDetail(for: item)
    }

    private var accessibilityDetail: String {
        [
            AgentConnectionsPresentation.itemDisplayDetail(for: item),
            evidenceDetail,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(
                systemName: AgentConnectionsPresentation.itemSystemImage(
                    for: item
                )
            )
            .foregroundStyle(tone.color)
            .frame(width: 20)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(AgentConnectionsPresentation.itemDisplayName(for: item))
                    .font(.callout.weight(.semibold))
                Text(AgentConnectionsPresentation.itemDisplayDetail(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let evidenceDetail {
                    Text(evidenceDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Text(AgentConnectionsPresentation.itemStatusTitle(for: item))
                .font(.caption.weight(.semibold))
                .foregroundStyle(tone.color)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(APCLocalization.format(
            .connectionsCheckAccessibilityFormat,
            AgentConnectionsPresentation.itemDisplayName(for: item),
            AgentConnectionsPresentation.itemStatusTitle(for: item),
            accessibilityDetail
        ))
        .accessibilityIdentifier(
            "connections.technical.check.\(item.code.rawValue).\(index)"
        )
    }
}

private struct ConnectionVerificationSummary: View {
    let source: AgentSource
    let status: AgentVerificationStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                APCLocalization.text(.connectionsVerificationTitle),
                systemImage: "person.crop.circle.badge.checkmark"
            )
            .font(.callout.weight(.semibold))

            Text(AgentConnectionsPresentation.verificationTitle(status))
                .font(.callout.weight(.medium))

            Text(AgentConnectionsPresentation.verificationDetail(status))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            "connections.technical.real-task.\(source.rawValue)"
        )
    }
}
