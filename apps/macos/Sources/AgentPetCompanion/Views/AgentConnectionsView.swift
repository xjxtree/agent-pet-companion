import AgentPetCompanionCore
import AppKit
import SwiftUI

enum AgentConnectionsCatalog {
    static let sources: [AgentSource] = [.codex, .claudeCode, .pi, .opencode]
}

enum AgentConnectionsLayout {
    static let listWidth: CGFloat = 190

    static func mode(for shellMode: ControlCenterShellMode) -> AgentConnectionsLayoutMode {
        switch shellMode {
        case .allColumns, .sidebarAndContent: .split
        case .singleContent: .compact
        }
    }
}

enum AgentConnectionsLayoutMode: Equatable, Sendable {
    case split
    case compact
}

enum ConnectionCheckRecoveryActionKind: String, Equatable, Sendable {
    case confirmManagedRepair = "confirm-managed-repair"
    case testChannel = "test-channel"
    case recheck
}

struct ConnectionCheckRecoveryAction: Equatable, Sendable {
    let kind: ConnectionCheckRecoveryActionKind
    let source: AgentSource

    var operation: AgentConnectionOperation? {
        switch kind {
        case .testChannel:
            AgentConnectionOperation(kind: .test, sources: [source])
        case .recheck:
            AgentConnectionOperation(kind: .check, sources: [source])
        case .confirmManagedRepair:
            nil
        }
    }
}

struct ConnectionCheckRecoveryButtonPresentation: Equatable {
    let title: String
    let accessibilityLabel: String
    let hint: String
    let systemImage: String
    let accessibilityIdentifier: String
    let isEnabled: Bool
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

enum AgentConnectionHealth: Equatable {
    case pending
    case needsAttention(Int)
    case actionRequired
    case lightCheck
    case unverified
    case limited
    case healthy

    var title: String {
        localizedTitle()
    }

    func localizedTitle(
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        switch self {
        case .pending: APCLocalization.text(.connectionsHealthPending, locale: locale)
        case let .needsAttention(count):
            APCLocalization.format(.connectionsHealthAttentionFormat, locale: locale, count)
        case .actionRequired:
            APCLocalization.text(.connectionsHealthActionRequired, locale: locale)
        case .lightCheck: APCLocalization.text(.connectionsHealthLight, locale: locale)
        case .unverified: APCLocalization.text(.connectionsHealthUnverified, locale: locale)
        case .limited: APCLocalization.text(.connectionsHealthLimited, locale: locale)
        case .healthy: APCLocalization.text(.connectionsHealthHealthy, locale: locale)
        }
    }

    var tone: AgentConnectionVisualTone {
        switch self {
        case .healthy: .good
        case .needsAttention, .actionRequired: .warning
        case .pending, .lightCheck, .unverified, .limited: .neutral
        }
    }

    var systemImage: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .needsAttention, .actionRequired: "exclamationmark.triangle.fill"
        case .pending: "circle.dotted"
        case .lightCheck: "clock.arrow.circlepath"
        case .unverified: "questionmark.circle"
        case .limited: "minus.circle"
        }
    }
}

enum AgentConnectionsPresentation {
    static func displayItems(in status: AgentConnectionStatus) -> [ConnectionCheckItem] {
        // Older PetCore versions reported the working directory used by their
        // host canary as a product-facing project check. Connection management
        // is Agent-scoped, so that implementation detail must not reintroduce a
        // project dimension in the App.
        let agentScopedItems = status.items.filter { $0.code != .projectDirectory }

        // PetCore keeps one typed result per managed file and host probe so its
        // diagnostics stay precise. Those rows deliberately share one localized
        // user-facing category, however, and rendering every file produces a
        // wall of identical "Managed Connector" / "Host Verification" rows.
        // Keep the most actionable result for each of those categories; the
        // single repair/recheck action still evaluates the complete Agent.
        let groupedCodes: Set<ConnectionCheckCode> = [.managedConnector, .hostVerification]
        var groupedIndexes: [ConnectionCheckCode: Int] = [:]
        var result: [ConnectionCheckItem] = []
        for item in agentScopedItems {
            guard groupedCodes.contains(item.code) else {
                result.append(item)
                continue
            }
            if let index = groupedIndexes[item.code] {
                if checkPriority(item.status) > checkPriority(result[index].status) {
                    result[index] = item
                }
            } else {
                groupedIndexes[item.code] = result.count
                result.append(item)
            }
        }
        return result
    }

    private static func checkPriority(_ status: CheckStatus) -> Int {
        switch status {
        case .missing: 5
        case .needsFix: 4
        case .unverified: 3
        case .unsupported: 2
        case .ok: 1
        case .notRequired: 0
        }
    }

    static func health(for status: AgentConnectionStatus?) -> AgentConnectionHealth {
        guard let status else { return .pending }
        let items = displayItems(in: status)
        let blockingItems = items.filter { $0.status.isBlocking }
        if !blockingItems.isEmpty {
            return .needsAttention(blockingItems.count)
        }
        if status.verification.status.requiresUserAction {
            return .actionRequired
        }
        if status.checkMode == .light {
            return .lightCheck
        }
        if status.verification.status == .unverified
            || items.contains(where: { $0.status == .unverified }) {
            return .unverified
        }
        if items.contains(where: { $0.status == .unsupported }) {
            return .limited
        }
        return .healthy
    }

    static func itemTitle(
        for item: ConnectionCheckItem,
        checkMode: ConnectionCheckMode,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        checkMode == .light && item.status == .ok
            ? APCLocalization.text(.connectionsItemLocated, locale: locale)
            : APCLocalizedPresentation.checkStatusTitle(item.status, locale: locale)
    }

    static func itemDisplayName(
        for item: ConnectionCheckItem,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch item.code {
        case .agentCLI: .connectionsCheckNameAgentCLI
        case .eventCLI: .connectionsCheckNameEventCLI
        case .projectDirectory, .unknown: .connectionsCheckNameGeneric
        case .agentVersion: .connectionsCheckNameAgentVersion
        case .managedConnector: .connectionsCheckNameManagedConnector
        case .claudeHooksPolicy: .connectionsCheckNameClaudeHooksPolicy
        case .hostRuntime: .connectionsCheckNameHostRuntime
        case .hostVerification: .connectionsCheckNameHostVerification
        case .eventDelivery: .connectionsCheckNameEventDelivery
        case .channelTest: .connectionsCheckNameChannelTest
        case .appServer: .connectionsCheckNameAppServer
        case .hostServer: .connectionsCheckNameHostServer
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func itemDisplayDetail(
        for item: ConnectionCheckItem,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let descriptionKey: APCLocalizationKey = switch item.code {
        case .agentCLI: .connectionsCheckDescriptionAgentCLI
        case .eventCLI: .connectionsCheckDescriptionEventCLI
        case .projectDirectory, .unknown: .connectionsCheckDescriptionGeneric
        case .agentVersion: .connectionsCheckDescriptionAgentVersion
        case .managedConnector: .connectionsCheckDescriptionManagedConnector
        case .claudeHooksPolicy: .connectionsCheckDescriptionClaudeHooksPolicy
        case .hostRuntime: .connectionsCheckDescriptionHostRuntime
        case .hostVerification: .connectionsCheckDescriptionHostVerification
        case .eventDelivery: .connectionsCheckDescriptionEventDelivery
        case .channelTest: .connectionsCheckDescriptionChannelTest
        case .appServer: .connectionsCheckDescriptionAppServer
        case .hostServer: .connectionsCheckDescriptionHostServer
        }
        return APCLocalization.text(descriptionKey, locale: locale)
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

    static func itemTone(
        for item: ConnectionCheckItem,
        checkMode: ConnectionCheckMode
    ) -> AgentConnectionVisualTone {
        if checkMode == .light, item.status == .ok {
            return .neutral
        }
        return switch item.status {
        case .ok: .good
        case .needsFix: .warning
        case .missing: .destructive
        case .unverified, .unsupported, .notRequired: .neutral
        }
    }

    static func itemSystemImage(
        for item: ConnectionCheckItem,
        checkMode: ConnectionCheckMode
    ) -> String {
        if checkMode == .light, item.status == .ok {
            return "location.circle.fill"
        }
        return switch item.status {
        case .ok: "checkmark.circle.fill"
        case .needsFix: "wrench.and.screwdriver.fill"
        case .missing: "xmark.circle.fill"
        case .unverified: "questionmark.circle.fill"
        case .unsupported: "minus.circle.fill"
        case .notRequired: "circle.dashed"
        }
    }

    static func recoveryAction(
        for item: ConnectionCheckItem,
        in status: AgentConnectionStatus
    ) -> ConnectionCheckRecoveryAction? {
        switch item.status {
        case .ok, .notRequired, .unsupported:
            return nil
        case .needsFix, .missing, .unverified:
            break
        }

        let kind: ConnectionCheckRecoveryActionKind
        switch item.recoveryAction ?? .recheck {
        case .chooseProjectDirectory:
            // Decode the legacy protocol value safely, but never reopen a
            // project-folder picker from an Agent-scoped connection page.
            kind = .recheck
        case .confirmManagedRepair:
            kind = status.capabilities.repairableConnectorIssue == true
                && status.capabilities.managedPathConflict == false
                ? .confirmManagedRepair
                : .recheck
        case .testChannel:
            kind = .testChannel
        case .recheck:
            kind = .recheck
        }
        return ConnectionCheckRecoveryAction(kind: kind, source: status.source)
    }

    static func recoveryButtonPresentation(
        for action: ConnectionCheckRecoveryAction,
        item: ConnectionCheckItem,
        itemIndex: Int,
        busy: Bool,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> ConnectionCheckRecoveryButtonPresentation {
        let titleKey: APCLocalizationKey
        let hintKey: APCLocalizationKey
        let systemImage: String
        switch action.kind {
        case .confirmManagedRepair:
            titleKey = .connectionsInstallRepair
            hintKey = .connectionsRepairHintPreview
            systemImage = "wrench.and.screwdriver"
        case .testChannel:
            titleKey = .connectionsTestChannel
            hintKey = .connectionsTestHint
            systemImage = "play.circle"
        case .recheck:
            titleKey = .connectionsRecheck
            hintKey = .connectionsRecheckHint
            systemImage = "arrow.clockwise"
        }
        let title = APCLocalization.text(titleKey, locale: locale)
        let itemName = itemDisplayName(for: item, locale: locale)
        return ConnectionCheckRecoveryButtonPresentation(
            title: title,
            accessibilityLabel: "\(action.source.title), \(itemName), \(title), \(itemIndex + 1)",
            hint: APCLocalization.text(
                busy ? .connectionsBusyHint : hintKey,
                locale: locale
            ),
            systemImage: systemImage,
            accessibilityIdentifier: "connections.detail.check-action.\(action.kind.rawValue).\(action.source.rawValue).\(itemIndex)",
            isEnabled: !busy
        )
    }

}

struct AgentConnectionsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.controlCenterShellMode) private var shellMode
    @SceneStorage("apc.connections.selected-source")
    private var selectedSourceRawValue = AgentSource.codex.rawValue
    @State private var confirmingRepairAll = false
    @State private var confirmingUninstallAll = false

    private var selectedSource: AgentSource {
        AgentSource(rawValue: selectedSourceRawValue) ?? .codex
    }

    private var sourceSelection: Binding<AgentSource> {
        Binding(
            get: { selectedSource },
            set: { selectedSourceRawValue = $0.rawValue }
        )
    }

    private var selectedStatus: AgentConnectionStatus? {
        store.connections.first { $0.source == selectedSource }
    }

    var body: some View {
        Group {
            switch AgentConnectionsLayout.mode(for: shellMode) {
            case .split:
                splitLayout
            case .compact:
                compactLayout
            }
        }
        .confirmationDialog(
            APCLocalization.text(.connectionsConfirmRepairAll),
            isPresented: $confirmingRepairAll,
            titleVisibility: .visible
        ) {
            Button(APCLocalization.format(
                .connectionsRepairCountFormat,
                repairableSources.count
            )) {
                store.repairConnections(repairableSources)
            }
            Button(APCLocalization.text(.commonCancel), role: .cancel) {}
        } message: {
            Text(repairAllConfirmationMessage)
        }
        .confirmationDialog(
            APCLocalization.text(.connectionsConfirmUninstallAll),
            isPresented: $confirmingUninstallAll,
            titleVisibility: .visible
        ) {
            Button(APCLocalization.format(
                .connectionsUninstallCountFormat,
                installedSources.count
            ), role: .destructive) {
                store.uninstallConnections(installedSources)
            }
            Button(APCLocalization.text(.commonCancel), role: .cancel) {}
        } message: {
            Text(uninstallAllConfirmationMessage)
        }
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                Button {
                    store.checkAllConnections()
                } label: {
                    Label(
                        APCLocalization.text(.connectionsCheckAll),
                        systemImage: "checkmark.seal"
                    )
                    .labelStyle(.iconOnly)
                }
                .help(APCLocalization.text(.connectionsCheckAllHint))
                .disabled(store.connectionOperationState.isRunning)
                .accessibilityIdentifier("connections.action.check-all")

                Menu {
                    Button(APCLocalization.text(.connectionsRepairAll)) {
                        confirmingRepairAll = true
                    }
                    .disabled(repairableSources.isEmpty || store.connectionOperationState.isRunning)

                    Divider()

                    Button(APCLocalization.text(.connectionsUninstallAll), role: .destructive) {
                        confirmingUninstallAll = true
                    }
                    .disabled(installedSources.isEmpty || store.connectionOperationState.isRunning)
                } label: {
                    Label(
                        APCLocalization.text(.connectionsBulkActions),
                        systemImage: "ellipsis.circle"
                    )
                    .labelStyle(.iconOnly)
                }
                .help(APCLocalization.text(.connectionsBulkActions))
                .disabled(store.connectionOperationState.isRunning)
                .accessibilityIdentifier("connections.action.bulk-menu")
            }
        }
        .accessibilityIdentifier("connections.root")
    }

    private var splitLayout: some View {
        HStack(spacing: 0) {
            AgentConnectionList(
                selection: sourceSelection,
                statuses: store.connections
            )
            .frame(width: AgentConnectionsLayout.listWidth)

            Divider()

            connectionDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier("connections.layout.split")
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            compactControls
            Divider()
            connectionDetail
        }
        .accessibilityIdentifier("connections.layout.compact")
    }

    private var compactControls: some View {
        ViewThatFits(in: .horizontal) {
            sourcePicker
                .frame(maxWidth: 280)
            sourcePicker
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var sourcePicker: some View {
        Picker(APCLocalization.text(.connectionsAgentLabel), selection: sourceSelection) {
            ForEach(AgentConnectionsCatalog.sources) { source in
                Text(source.title).tag(source)
            }
        }
        .pickerStyle(.menu)
        .accessibilityLabel(APCLocalization.text(.connectionsSourcePicker))
        .accessibilityIdentifier("connections.agent-picker")
    }

    private var connectionDetail: some View {
        ConnectionCheckDetail(
            source: selectedSource,
            status: selectedStatus
        )
        .id(selectedSource)
    }

    private var repairableStatuses: [AgentConnectionStatus] {
        store.connections.filter(\.hasRepairableConnectorIssue)
    }

    private var installedStatuses: [AgentConnectionStatus] {
        store.connections.filter(\.canUninstallManagedConnector)
    }

    private var repairableSources: [AgentSource] {
        repairableStatuses.map(\.source)
    }

    private var installedSources: [AgentSource] {
        installedStatuses.map(\.source)
    }

    private var repairAllConfirmationMessage: String {
        guard !repairableStatuses.isEmpty else {
            return APCLocalization.text(.connectionsNoRepairAll)
        }
        let names = repairableStatuses.map(\.source.title).joined(separator: "、")
        let paths = repairableStatuses.flatMap(\.installPaths)
        return managedChangeMessage(
            action: APCLocalization.text(.connectionsActionInstallUpdate),
            names: names,
            paths: paths
        )
    }

    private var uninstallAllConfirmationMessage: String {
        guard !installedStatuses.isEmpty else {
            return APCLocalization.text(.connectionsNoUninstallAll)
        }
        let names = installedStatuses.map(\.source.title).joined(separator: "、")
        let paths = installedStatuses.flatMap(\.installPaths)
        return managedChangeMessage(
            action: APCLocalization.text(.connectionsActionRemove),
            names: names,
            paths: paths
        )
    }

    private func managedChangeMessage(
        action: String,
        names: String,
        paths: [String]
    ) -> String {
        var lines = [APCLocalization.format(
            .connectionsManagedChangeFormat,
            action,
            names
        )]
        if !paths.isEmpty {
            lines.append(contentsOf: paths.prefix(8))
            if paths.count > 8 {
                lines.append(APCLocalization.format(
                    .connectionsMoreLocationsFormat,
                    paths.count - 8
                ))
            }
        }
        lines.append(APCLocalization.text(.connectionsSafetySummary))
        return lines.joined(separator: "\n")
    }
}

struct AgentConnectionList: View {
    @Binding var selection: AgentSource
    let statuses: [AgentConnectionStatus]

    var body: some View {
        List(selection: $selection) {
            ForEach(AgentConnectionsCatalog.sources) { source in
                AgentConnectionListRow(
                    source: source,
                    status: status(for: source)
                )
                .tag(source)
                .accessibilityIdentifier("connections.agent.\(source.rawValue)")
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel(APCLocalization.text(.connectionsListAccessibility))
        .accessibilityIdentifier("connections.agent-list")
    }

    private func status(for source: AgentSource) -> AgentConnectionStatus? {
        statuses.first { $0.source == source }
    }
}

private struct AgentConnectionListRow: View {
    let source: AgentSource
    let status: AgentConnectionStatus?

    private var health: AgentConnectionHealth {
        AgentConnectionsPresentation.health(for: status)
    }

    var body: some View {
        HStack(spacing: 10) {
            AgentIconView(source: source, size: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                Text(rowDetail)
                    .font(.caption2)
                    .foregroundStyle(health.tone.color)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(APCLocalization.format(
            .connectionsMetadataFormat,
            source.title,
            rowDetail
        ))
    }

    private var rowDetail: String {
        health.title
    }
}

struct ConnectionCheckDetail: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirmingRepair = false
    @State private var confirmingUninstall = false

    let source: AgentSource
    let status: AgentConnectionStatus?

    private var busy: Bool {
        store.connectionOperationState.isRunning
    }

    private var health: AgentConnectionHealth {
        AgentConnectionsPresentation.health(for: status)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                selectedAgentHeader
                ConnectionActionBar(source: source, busy: busy)
                operationNotice

                if let status {
                    connectionChecks(status)
                    managedActions(status)
                } else {
                    noSnapshotState
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .confirmationDialog(
            APCLocalization.format(.connectionsConfirmRepairFormat, source.title),
            isPresented: $confirmingRepair,
            titleVisibility: .visible
        ) {
            Button(APCLocalization.text(.connectionsWriteRepair)) {
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
            Button(APCLocalization.text(.connectionsUninstall), role: .destructive) {
                store.uninstallConnection(source)
            }
            Button(APCLocalization.text(.commonCancel), role: .cancel) {}
        } message: {
            Text(uninstallConfirmationMessage)
        }
        .accessibilityIdentifier("connections.detail")
    }

    private var selectedAgentHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            AgentIconView(source: source, size: 42)

            Text(source.title)
                .font(.title2.weight(.semibold))

            Spacer(minLength: 8)

            ConnectionStatusPill(
                title: health.title,
                tone: health.tone,
                systemImage: health.systemImage
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connections.detail.agent-header")
    }

    @ViewBuilder
    private var operationNotice: some View {
        if let operation = store.connectionOperationState.runningOperation {
            HStack(alignment: .top, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(connectionOperationTitle(operation))
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(APCLocalization.text(.connectionsOperationSerial))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(APCDesign.accentSoft)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("connections.operation-status")
        } else if let failure = store.connectionOperationState.failedOperation {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    APCLocalization.text(.connectionsOperationFailed),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(APCDesign.destructive)

                Text(connectionOperationTitle(failure.operation))
                    .font(.caption.weight(.semibold))
                Text(AgentConnectionsPresentation.operationFailureDetail(failure.reason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                HStack(spacing: 10) {
                    Button(APCLocalization.text(.commonRetry)) {
                        store.retryConnectionOperation()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("connections.operation.retry")

                    Button(APCLocalization.text(.connectionsOperationDismiss)) {
                        store.dismissConnectionOperationNotice()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("connections.operation.dismiss")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(APCDesign.destructive.opacity(0.08))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(APCDesign.destructive.opacity(0.45), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("connections.operation-failure")
        }
    }

    private func connectionOperationTitle(
        _ operation: AgentConnectionOperation
    ) -> String {
        let key: APCLocalizationKey = switch operation.kind {
        case .check: .connectionsOperationCheck
        case .test: .connectionsOperationTest
        case .repair: .connectionsOperationRepair
        case .uninstall: .connectionsOperationUninstall
        }
        let action = APCLocalization.text(key)
        let names = operation.sources.map(\.shortTitle).joined(separator: ", ")
        return APCLocalization.format(.connectionsOperationTitleFormat, action, names)
    }

    private func connectionChecks(_ status: AgentConnectionStatus) -> some View {
        let items = AgentConnectionsPresentation.displayItems(in: status)
        return ConnectionPanel(title: APCLocalization.text(.connectionsChecksTitle), systemImage: "checklist") {
            if items.isEmpty {
                Text(APCLocalization.text(.connectionsChecksEmpty))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    // A localized/human-readable row name is not identity.
                    // The typed result order is bounded and stable for one
                    // check response, so duplicate names remain distinct.
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        ConnectionCheckRow(
                            item: item,
                            checkMode: status.checkMode,
                            index: index,
                            recoveryAction: AgentConnectionsPresentation.recoveryAction(
                                for: item,
                                in: status
                            ),
                            busy: busy,
                            onRecovery: performRecoveryAction
                        )
                        if index < items.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("connections.detail.checks")
    }

    private func performRecoveryAction(_ action: ConnectionCheckRecoveryAction) {
        switch action.kind {
        case .confirmManagedRepair:
            guard action.source == source,
                  status?.capabilities.repairableConnectorIssue == true,
                  status?.capabilities.managedPathConflict == false else { return }
            confirmingRepair = true
        case .testChannel:
            store.sendConnectionTestEvent(action.source)
        case .recheck:
            store.checkConnection(action.source)
        }
    }

    @ViewBuilder
    private func managedActions(_ status: AgentConnectionStatus) -> some View {
        if status.hasRepairableConnectorIssue || status.canUninstallManagedConnector {
            HStack(spacing: 10) {
                Label(
                    APCLocalization.text(.connectionsManagedTitle),
                    systemImage: "shippingbox"
                )
                .font(.callout.weight(.semibold))

                Spacer(minLength: 12)

                if status.hasRepairableConnectorIssue {
                    Button {
                        confirmingRepair = true
                    } label: {
                        Label(
                            APCLocalization.text(
                                status.connectorInstalled == true
                                    ? .connectionsRepair
                                    : .connectionsInstallRepair
                            ),
                            systemImage: "wrench.and.screwdriver"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                    .accessibilityLabel(APCLocalization.format(
                        .connectionsRepairAccessibilityFormat,
                        source.title
                    ))
                    .accessibilityHint(repairHint(for: status))
                    .accessibilityIdentifier("connections.action.repair.\(source.rawValue)")
                }

                if status.canUninstallManagedConnector {
                    Button {
                        confirmingUninstall = true
                    } label: {
                        Label(APCLocalization.text(.connectionsUninstall), systemImage: "trash")
                            .foregroundStyle(APCDesign.destructive)
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                    .accessibilityLabel(APCLocalization.format(
                        .connectionsUninstallAccessibilityFormat,
                        source.title
                    ))
                    .accessibilityHint(APCLocalization.text(.connectionsUninstallHint))
                    .accessibilityIdentifier("connections.action.uninstall.\(source.rawValue)")
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityIdentifier("connections.detail.managed-actions")
        }
    }

    private var noSnapshotState: some View {
        ContentUnavailableView {
            Label(APCLocalization.text(.connectionsNoSnapshot), systemImage: "antenna.radiowaves.left.and.right.slash")
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .accessibilityIdentifier("connections.detail.empty")
    }

    private var repairConfirmationMessage: String {
        guard let status, status.hasRepairableConnectorIssue else {
            return APCLocalization.text(.connectionsRepairUnavailable)
        }
        var lines = [APCLocalization.text(.connectionsRepairFilesIntro)]
        lines.append(contentsOf: status.installPaths)
        lines.append(APCLocalization.text(.connectionsRepairSafety))
        return lines.joined(separator: "\n")
    }

    private var uninstallConfirmationMessage: String {
        guard let status else {
            return APCLocalization.text(.connectionsUninstallUnavailable)
        }
        var lines = [APCLocalization.text(.connectionsUninstallFilesIntro)]
        if status.installPaths.isEmpty {
            lines.append(APCLocalization.text(.connectionsPathsUnreported))
        } else {
            lines.append(contentsOf: status.installPaths)
        }
        lines.append(APCLocalization.text(.connectionsSafetySummary))
        return lines.joined(separator: "\n")
    }

    private func repairHint(for status: AgentConnectionStatus) -> String {
        if busy {
            return APCLocalization.text(.connectionsBusyHint)
        }
        if status.hasRepairableConnectorIssue {
            return APCLocalization.text(.connectionsRepairHintPreview)
        }
        if AgentConnectionsPresentation.displayItems(in: status)
            .allSatisfy({ !$0.status.isBlocking }) {
            return APCLocalization.text(.connectionsRepairHintNone)
        }
        return APCLocalization.text(.connectionsRepairHintManual)
    }
}

struct ConnectionActionBar: View {
    @EnvironmentObject private var store: AppStore
    let source: AgentSource
    let busy: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button {
                store.checkConnection(source)
            } label: {
                Label(APCLocalization.text(.connectionsRecheck), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(busy)
            .help(APCLocalization.text(
                busy ? .connectionsBusyHint : .connectionsRecheckHint
            ))
            .accessibilityHint(APCLocalization.text(
                busy ? .connectionsBusyHint : .connectionsRecheckHint
            ))
            .accessibilityIdentifier("connections.action.check.\(source.rawValue)")

            Button {
                store.sendConnectionTestEvent(source)
            } label: {
                Label(APCLocalization.text(.connectionsTestChannel), systemImage: "play.circle")
            }
            .buttonStyle(.bordered)
            .disabled(busy)
            .help(APCLocalization.format(.connectionsTestDetailFormat, source.title))
            .accessibilityHint(APCLocalization.text(.connectionsTestHint))
            .accessibilityIdentifier("connections.action.test.\(source.rawValue)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connections.detail.action-bar")
    }
}

private struct ConnectionCheckRow: View {
    let item: ConnectionCheckItem
    let checkMode: ConnectionCheckMode
    let index: Int
    let recoveryAction: ConnectionCheckRecoveryAction?
    let busy: Bool
    let onRecovery: (ConnectionCheckRecoveryAction) -> Void

    private var tone: AgentConnectionVisualTone {
        AgentConnectionsPresentation.itemTone(for: item, checkMode: checkMode)
    }

    private var statusTitle: String {
        AgentConnectionsPresentation.itemTitle(for: item, checkMode: checkMode)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(
                systemName: AgentConnectionsPresentation.itemSystemImage(
                    for: item,
                    checkMode: checkMode
                )
            )
            .font(.body)
            .foregroundStyle(tone.color)
            .frame(width: 20)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(AgentConnectionsPresentation.itemDisplayName(for: item))
                    .font(.callout.weight(.semibold))
                Text(AgentConnectionsPresentation.itemDisplayDetail(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(checkAccessibilityLabel)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                Text(statusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tone.color)
                    .accessibilityHidden(true)

                if let recoveryAction {
                    let presentation = AgentConnectionsPresentation.recoveryButtonPresentation(
                        for: recoveryAction,
                        item: item,
                        itemIndex: index,
                        busy: busy
                    )
                    Button {
                        onRecovery(recoveryAction)
                    } label: {
                        Label(presentation.title, systemImage: presentation.systemImage)
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(!presentation.isEnabled)
                    .accessibilityLabel(presentation.accessibilityLabel)
                    .accessibilityHint(presentation.hint)
                    .accessibilityIdentifier(presentation.accessibilityIdentifier)
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connections.detail.check.\(item.status.rawValue).\(index)")
    }

    private var checkAccessibilityLabel: String {
        APCLocalization.format(
            .connectionsCheckAccessibilityFormat,
            AgentConnectionsPresentation.itemDisplayName(for: item),
            statusTitle,
            AgentConnectionsPresentation.itemDisplayDetail(for: item)
        )
    }
}

private struct ConnectionPanel<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Divider()
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

private struct ConnectionStatusPill: View {
    let title: String
    let tone: AgentConnectionVisualTone
    let systemImage: String?

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tone.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tone.color.opacity(0.10), in: Capsule())
        .overlay {
            Capsule()
                .stroke(tone.color.opacity(0.32), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
    }
}
