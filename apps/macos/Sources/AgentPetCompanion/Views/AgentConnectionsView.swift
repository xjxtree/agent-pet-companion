import AgentPetCompanionCore
import AppKit
import Foundation
import SwiftUI

// Kept as a source-compatible presentation contract for existing validation.
// UI Next no longer lays out overview or Agent cards with these grids.
enum ConnectionGridLayout {
    static let overviewColumns = [
        GridItem(.adaptive(minimum: 140), spacing: 12, alignment: .top)
    ]
    static let cardColumns = [
        GridItem(.adaptive(minimum: 260), spacing: 14, alignment: .top)
    ]
}

enum AgentConnectionsNextCatalog {
    static let sources: [AgentSource] = [.codex, .claudeCode, .pi, .opencode]
}

enum AgentConnectionsNextLayout {
    static let fullLayoutMinimumWidth: CGFloat = 1_120
    static let listDetailMinimumWidth: CGFloat = 880
    static let listWidth: CGFloat = 190
    static let inspectorWidth: CGFloat = 292

    static func mode(for shellMode: ControlCenterShellMode) -> AgentConnectionsLayoutMode {
        switch shellMode {
        case .allColumns: .full
        case .sidebarAndContent: .listDetail
        case .singleContent: .compact
        }
    }
}

enum AgentConnectionsLayoutMode: Equatable, Sendable {
    case full
    case listDetail
    case compact
}

enum AgentConnectionNoSnapshotActionEmphasis: Equatable, Sendable {
    case hidden
    case secondary
    case prominent
}

enum ConnectionCheckRecoveryActionKind: String, Equatable, Sendable {
    case chooseProjectDirectory = "choose-project-directory"
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
        case .chooseProjectDirectory, .confirmManagedRepair:
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

enum AgentConnectionsNextPresentation {
    static func noSnapshotActionEmphasis(
        status: AgentConnectionStatus?,
        operationState: AgentConnectionOperationState
    ) -> AgentConnectionNoSnapshotActionEmphasis {
        guard status == nil else { return .hidden }
        return operationState.failedOperation == nil ? .prominent : .secondary
    }

    static func health(for status: AgentConnectionStatus?) -> AgentConnectionHealth {
        guard let status else { return .pending }
        if !status.blockingItems.isEmpty {
            return .needsAttention(status.blockingItems.count)
        }
        if status.verification.status.requiresUserAction {
            return .actionRequired
        }
        if status.checkMode == .light {
            return .lightCheck
        }
        if status.verification.status == .unverified || !status.unverifiedItems.isEmpty {
            return .unverified
        }
        if !status.unsupportedItems.isEmpty {
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
        case .projectDirectory: .connectionsCheckNameProjectDirectory
        case .agentVersion: .connectionsCheckNameAgentVersion
        case .managedConnector: .connectionsCheckNameManagedConnector
        case .claudeHooksPolicy: .connectionsCheckNameClaudeHooksPolicy
        case .hostRuntime: .connectionsCheckNameHostRuntime
        case .hostVerification: .connectionsCheckNameHostVerification
        case .eventDelivery: .connectionsCheckNameEventDelivery
        case .channelTest: .connectionsCheckNameChannelTest
        case .appServer: .connectionsCheckNameAppServer
        case .hostServer: .connectionsCheckNameHostServer
        case .unknown: .connectionsCheckNameGeneric
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
        case .projectDirectory: .connectionsCheckDescriptionProjectDirectory
        case .agentVersion: .connectionsCheckDescriptionAgentVersion
        case .managedConnector: .connectionsCheckDescriptionManagedConnector
        case .claudeHooksPolicy: .connectionsCheckDescriptionClaudeHooksPolicy
        case .hostRuntime: .connectionsCheckDescriptionHostRuntime
        case .hostVerification: .connectionsCheckDescriptionHostVerification
        case .eventDelivery: .connectionsCheckDescriptionEventDelivery
        case .channelTest: .connectionsCheckDescriptionChannelTest
        case .appServer: .connectionsCheckDescriptionAppServer
        case .hostServer: .connectionsCheckDescriptionHostServer
        case .unknown: .connectionsCheckDescriptionGeneric
        }
        return APCLocalization.format(
            .connectionsCheckDetailFormat,
            locale: locale,
            APCLocalizedPresentation.checkStatusTitle(item.status, locale: locale),
            APCLocalization.text(descriptionKey, locale: locale)
        )
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
            kind = .chooseProjectDirectory
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
        case .chooseProjectDirectory:
            titleKey = .connectionsChooseDirectory
            hintKey = .connectionsDirectoryDetail
            systemImage = "folder"
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

    static func checkMetadata(
        for status: AgentConnectionStatus,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let mode = APCLocalizedPresentation.connectionCheckModeTitle(
            status.checkMode,
            locale: locale
        )
        guard let checkedAt = status.checkedAt else {
            return mode
        }
        guard let date = connectionDate(from: checkedAt) else {
            return mode
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return APCLocalization.format(
            .connectionsMetadataFormat,
            locale: locale,
            mode,
            formatter.string(from: date)
        )
    }

    static func connectionDate(from value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]
        return fractionalFormatter.date(from: value) ?? standardFormatter.date(from: value)
    }
}

struct AgentConnectionsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.controlCenterShellMode) private var shellMode
    @Environment(\.apcVisualFixtureSelections) private var fixtureSelections
    @SceneStorage("apc.connections.selected-source")
    private var selectedSourceRawValue = AgentSource.codex.rawValue
    @State private var confirmingRepairAll = false
    @State private var confirmingUninstallAll = false
    @State private var showingEnvironmentInspector = false

    private var selectedSource: AgentSource {
        fixtureSelections.resolveConnectionSource(
            stored: AgentSource(rawValue: selectedSourceRawValue) ?? .codex
        )
    }

    private var sourceSelection: Binding<AgentSource> {
        Binding(
            get: { selectedSource },
            set: {
                guard fixtureSelections.connectionSource == nil else { return }
                selectedSourceRawValue = $0.rawValue
            }
        )
    }

    private var selectedStatus: AgentConnectionStatus? {
        store.connections.first { $0.source == selectedSource }
    }

    var body: some View {
        Group {
            switch AgentConnectionsNextLayout.mode(for: shellMode) {
            case .full:
                fullLayout
            case .listDetail:
                listDetailLayout
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
        .sheet(isPresented: $showingEnvironmentInspector) {
            ConnectionEnvironmentInspector(
                source: selectedSource,
                status: selectedStatus
            )
            .environmentObject(store)
            .frame(minWidth: 520, minHeight: 520)
            .accessibilityIdentifier("connections.inspector-sheet")
        }
        .toolbar {
            if !shellMode.keepsInspectorPresented {
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showingEnvironmentInspector.toggle()
                    } label: {
                        Label(
                            APCLocalization.text(.connectionsEnvironmentTitle),
                            systemImage: "sidebar.right"
                        )
                    }
                    .accessibilityIdentifier("connections.inspector-toggle")
                }
            }
        }
        .accessibilityIdentifier("connections.root")
    }

    private var fullLayout: some View {
        HStack(spacing: 0) {
            AgentConnectionList(
                selection: sourceSelection,
                statuses: store.connections
            )
            .frame(width: AgentConnectionsNextLayout.listWidth)

            Divider()

            connectionDetail(showsEnvironmentAction: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            connectionInspector
                .frame(width: AgentConnectionsNextLayout.inspectorWidth)
        }
        .accessibilityIdentifier("connections.layout.wide")
    }

    private var listDetailLayout: some View {
        HStack(spacing: 0) {
            AgentConnectionList(
                selection: sourceSelection,
                statuses: store.connections
            )
            .frame(width: AgentConnectionsNextLayout.listWidth)

            Divider()

            connectionDetail(showsEnvironmentAction: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier("connections.layout.list-detail")
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            compactControls
            Divider()
            connectionDetail(showsEnvironmentAction: false)
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
            ForEach(AgentConnectionsNextCatalog.sources) { source in
                Text(source.title).tag(source)
            }
        }
        .pickerStyle(.menu)
        .accessibilityLabel(APCLocalization.text(.connectionsSourcePicker))
        .accessibilityIdentifier("connections.agent-picker")
    }

    private func connectionDetail(showsEnvironmentAction: Bool) -> some View {
        ConnectionCheckDetail(
            source: selectedSource,
            status: selectedStatus,
            repairableCount: repairableSources.count,
            installedCount: installedSources.count,
            onRepairAll: { confirmingRepairAll = true },
            onUninstallAll: { confirmingUninstallAll = true },
            onShowEnvironment: { showingEnvironmentInspector = true },
            showsEnvironmentAction: showsEnvironmentAction
        )
        .id(selectedSource)
    }

    private var connectionInspector: some View {
        ConnectionEnvironmentInspector(
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
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(APCLocalization.text(.connectionsListTitle))
                    .font(.headline)
                Spacer()
                Text("\(AgentConnectionsNextCatalog.sources.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)

            Divider()

            List(selection: $selection) {
                ForEach(AgentConnectionsNextCatalog.sources) { source in
                    AgentConnectionListRow(
                        source: source,
                        status: status(for: source)
                    )
                    .tag(source)
                    .accessibilityIdentifier("connections.agent.\(source.rawValue)")
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
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
        AgentConnectionsNextPresentation.health(for: status)
    }

    var body: some View {
        HStack(spacing: 10) {
            AgentIconView(source: source, size: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(source.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 2)

                    Image(systemName: health.systemImage)
                        .font(.caption)
                        .foregroundStyle(health.tone.color)
                        .accessibilityHidden(true)
                }

                Text(rowDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
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
        guard let status else { return health.title }
        return APCLocalization.format(
            .connectionsMetadataFormat,
            APCLocalizedPresentation.connectionCheckModeTitle(status.checkMode),
            health.title
        )
    }
}

struct ConnectionCheckDetail: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirmingRepair = false
    @State private var confirmingUninstall = false

    let source: AgentSource
    let status: AgentConnectionStatus?
    let repairableCount: Int
    let installedCount: Int
    let onRepairAll: () -> Void
    let onUninstallAll: () -> Void
    let onShowEnvironment: () -> Void
    let showsEnvironmentAction: Bool

    private var busy: Bool {
        store.connectionOperationState.isRunning
    }

    private var health: AgentConnectionHealth {
        AgentConnectionsNextPresentation.health(for: status)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageActionHeader
                Divider()
                selectedAgentHeader
                ConnectionActionBar(source: source, busy: busy)
                operationNotice

                if let status {
                    AgentVerificationSection(
                        source: source,
                        verification: status.verification
                    )
                    connectionChecks(status)
                    AgentCapabilitiesSection(capabilities: status.capabilities)
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

    private var pageActionHeader: some View {
        PageActionHeader(
            title: APCLocalization.text(.connectionsPageTitle),
            subtitle: APCLocalization.text(.connectionsPageSubtitle)
        ) {
            globalActions
        }
        .accessibilityIdentifier("connections.detail.header")
    }

    private var globalActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                globalActionItems
            }

            VStack(alignment: .leading, spacing: 8) {
                globalActionItems
            }
        }
    }

    @ViewBuilder
    private var globalActionItems: some View {
        Button {
            store.checkAllConnections()
        } label: {
            Label(APCLocalization.text(.connectionsCheckAll), systemImage: "checkmark.seal")
        }
        .buttonStyle(.bordered)
        .disabled(busy)
        .accessibilityHint(APCLocalization.text(
            busy ? .connectionsBusyHint : .connectionsCheckAllHint
        ))
        .accessibilityIdentifier("connections.action.check-all")

        Menu {
            Button(APCLocalization.text(.connectionsRepairAll)) {
                onRepairAll()
            }
            .disabled(repairableCount == 0 || busy)

            Divider()

            Button(APCLocalization.text(.connectionsUninstallAll), role: .destructive) {
                onUninstallAll()
            }
            .disabled(installedCount == 0 || busy)
        } label: {
            Label(APCLocalization.text(.connectionsBulkActions), systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .disabled(busy)
        .accessibilityIdentifier("connections.action.bulk-menu")

        if showsEnvironmentAction {
            Button(action: onShowEnvironment) {
                Label(
                    APCLocalization.text(.connectionsEnvironmentTitle),
                    systemImage: "sidebar.right"
                )
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("connections.action.environment")
        }
    }

    private var selectedAgentHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            AgentIconView(source: source, size: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(source.title)
                    .font(.title2.weight(.semibold))
                Text(status.map {
                    AgentConnectionsNextPresentation.checkMetadata(for: $0)
                } ?? APCLocalization.text(.connectionsNoSnapshot))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                Text(AgentConnectionsNextPresentation.operationFailureDetail(failure.reason))
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
        ConnectionPanel(title: APCLocalization.text(.connectionsChecksTitle), systemImage: "checklist") {
            if status.items.isEmpty {
                Text(APCLocalization.text(.connectionsChecksEmpty))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    // A localized/human-readable row name is not identity.
                    // The typed result order is bounded and stable for one
                    // check response, so duplicate names remain distinct.
                    ForEach(Array(status.items.enumerated()), id: \.offset) { index, item in
                        ConnectionCheckRow(
                            item: item,
                            checkMode: status.checkMode,
                            index: index,
                            recoveryAction: AgentConnectionsNextPresentation.recoveryAction(
                                for: item,
                                in: status
                            ),
                            busy: busy,
                            onRecovery: performRecoveryAction
                        )
                        if index < status.items.count - 1 {
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
        case .chooseProjectDirectory:
            store.chooseConnectionCheckDirectory()
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

    private func managedActions(_ status: AgentConnectionStatus) -> some View {
        ConnectionPanel(title: APCLocalization.text(.connectionsManagedTitle), systemImage: "shippingbox") {
            VStack(alignment: .leading, spacing: 12) {
                Text(APCLocalization.text(.connectionsManagedDetail))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
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
                    .disabled(!status.hasRepairableConnectorIssue || busy)
                    .accessibilityLabel(APCLocalization.format(
                        .connectionsRepairAccessibilityFormat,
                        source.title
                    ))
                    .accessibilityHint(repairHint(for: status))
                    .accessibilityIdentifier("connections.action.repair.\(source.rawValue)")

                    Button {
                        confirmingUninstall = true
                    } label: {
                        Label(APCLocalization.text(.connectionsUninstall), systemImage: "trash")
                            .foregroundStyle(
                                status.canUninstallManagedConnector
                                    ? APCDesign.destructive
                                    : .secondary
                            )
                    }
                    .buttonStyle(.bordered)
                    .disabled(!status.canUninstallManagedConnector || busy)
                    .accessibilityLabel(APCLocalization.format(
                        .connectionsUninstallAccessibilityFormat,
                        source.title
                    ))
                    .accessibilityHint(APCLocalization.text(.connectionsUninstallHint))
                    .accessibilityIdentifier("connections.action.uninstall.\(source.rawValue)")
                }
            }
        }
        .accessibilityIdentifier("connections.detail.managed-actions")
    }

    private var noSnapshotState: some View {
        ContentUnavailableView {
            Label(APCLocalization.text(.connectionsNoSnapshot), systemImage: "antenna.radiowaves.left.and.right.slash")
        } description: {
            Text(APCLocalization.format(
                .connectionsSnapshotDescriptionFormat,
                source.title
            ))
        } actions: {
            noSnapshotCheckAction
        }
        .frame(maxWidth: .infinity, minHeight: 250)
        .accessibilityIdentifier("connections.detail.empty")
    }

    @ViewBuilder
    private var noSnapshotCheckAction: some View {
        switch AgentConnectionsNextPresentation.noSnapshotActionEmphasis(
            status: status,
            operationState: store.connectionOperationState
        ) {
        case .hidden:
            EmptyView()
        case .secondary:
            noSnapshotCheckButton
                .buttonStyle(.bordered)
        case .prominent:
            noSnapshotCheckButton
                .buttonStyle(.borderedProminent)
        }
    }

    private var noSnapshotCheckButton: some View {
        Button(APCLocalization.format(.connectionsCheckSourceFormat, source.title)) {
            store.checkConnection(source)
        }
        .disabled(busy)
        .accessibilityIdentifier("connections.empty.check.\(source.rawValue)")
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
        if status.blockingItems.isEmpty {
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    store.checkConnection(source)
                } label: {
                    Label(APCLocalization.text(.connectionsRecheck), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(busy)
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
                .accessibilityHint(APCLocalization.text(.connectionsTestHint))
                .accessibilityIdentifier("connections.action.test.\(source.rawValue)")
            }

            Text(APCLocalization.format(.connectionsTestDetailFormat, source.title))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        AgentConnectionsNextPresentation.itemTone(for: item, checkMode: checkMode)
    }

    private var statusTitle: String {
        AgentConnectionsNextPresentation.itemTitle(for: item, checkMode: checkMode)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(
                systemName: AgentConnectionsNextPresentation.itemSystemImage(
                    for: item,
                    checkMode: checkMode
                )
            )
            .font(.body)
            .foregroundStyle(tone.color)
            .frame(width: 20)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(AgentConnectionsNextPresentation.itemDisplayName(for: item))
                    .font(.callout.weight(.semibold))
                Text(AgentConnectionsNextPresentation.itemDisplayDetail(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(checkAccessibilityLabel)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                ConnectionStatusPill(
                    title: statusTitle,
                    tone: tone,
                    systemImage: nil
                )
                .accessibilityHidden(true)

                if let recoveryAction {
                    let presentation = AgentConnectionsNextPresentation.recoveryButtonPresentation(
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
            AgentConnectionsNextPresentation.itemDisplayName(for: item),
            statusTitle,
            AgentConnectionsNextPresentation.itemDisplayDetail(for: item)
        )
    }
}

private struct AgentVerificationSection: View {
    let source: AgentSource
    let verification: AgentVerification

    private var tone: AgentConnectionVisualTone {
        switch verification.status {
        case .verified: .good
        case .actionRequired: .warning
        case .unverified, .notRequired: .neutral
        }
    }

    var body: some View {
        ConnectionPanel(title: APCLocalization.text(.connectionsVerificationTitle), systemImage: "checkmark.shield") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(resolvedTitle)
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 8)
                    ConnectionStatusPill(
                        title: APCLocalizedPresentation.verificationStatusTitle(
                            verification.status
                        ),
                        tone: tone,
                        systemImage: nil
                    )
                }

                Text(resolvedDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if verification.status != .verified,
                   verification.status != .notRequired {
                    Label(
                        APCLocalization.format(
                            .connectionsVerificationInstructionFormat,
                            source.title
                        ),
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundStyle(verification.status.requiresUserAction ? APCDesign.warning : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if hasMetadata {
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        if let checkedCWD = nonEmpty(verification.checkedCWD) {
                            metadataRow(
                                title: APCLocalization.text(.connectionsMetadataCWD),
                                value: checkedCWD
                            )
                        }
                        if let lastEvent = nonEmpty(verification.lastEvent) {
                            metadataRow(
                                title: APCLocalization.text(.connectionsMetadataLastReceipt),
                                value: lastEvent
                            )
                        }
                        if let lastVerifiedAt = nonEmpty(verification.lastVerifiedAt) {
                            metadataRow(
                                title: APCLocalization.text(.connectionsMetadataVerifiedAt),
                                value: localizedTimestamp(lastVerifiedAt)
                            )
                        }
                    }
                }

            }
        }
        .accessibilityIdentifier("connections.detail.verification")
    }

    private var resolvedTitle: String {
        let key: APCLocalizationKey = switch verification.status {
        case .verified: .connectionsVerificationVerifiedTitle
        case .actionRequired: .connectionsVerificationActionTitle
        case .unverified: .connectionsVerificationPendingTitle
        case .notRequired: .connectionsVerificationNotRequiredTitle
        }
        return APCLocalization.text(key)
    }

    private var resolvedDetail: String {
        let key: APCLocalizationKey = switch verification.status {
        case .verified: .connectionsVerificationVerifiedDetail
        case .actionRequired: .connectionsVerificationActionDetail
        case .unverified: .connectionsVerificationPendingDetail
        case .notRequired: .connectionsVerificationNotRequiredDetail
        }
        return APCLocalization.text(key)
    }

    private var hasMetadata: Bool {
        nonEmpty(verification.checkedCWD) != nil
            || nonEmpty(verification.lastEvent) != nil
            || nonEmpty(verification.lastVerifiedAt) != nil
    }

    private func metadataRow(title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func localizedTimestamp(_ value: String) -> String {
        guard let date = AgentConnectionsNextPresentation.connectionDate(from: value) else {
            return value
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: APCLocalization.interfaceLocaleIdentifier)
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

private struct AgentCapabilitiesSection: View {
    @State private var isExpanded = false
    let capabilities: AgentConnectorCapabilities

    var body: some View {
        ConnectionPanel(title: APCLocalization.text(.connectionsCapabilitiesTitle), systemImage: "list.bullet.rectangle") {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    if capabilities.hasReportedCapabilities {
                        capabilityList(
                            title: APCLocalization.text(.connectionsCapabilitiesAudited),
                            values: capabilities.auditedEvents
                        )
                        capabilityList(
                            title: APCLocalization.text(.connectionsCapabilitiesSubscribed),
                            values: capabilities.subscribedEvents
                        )
                        capabilityList(
                            title: APCLocalization.text(.connectionsCapabilitiesMapped),
                            values: capabilities.mappedInformation
                        )
                        capabilityList(
                            title: APCLocalization.text(.connectionsCapabilitiesPrivacy),
                            values: capabilities.privacyExclusions
                        )
                    } else {
                        Text(APCLocalization.text(.connectionsCapabilitiesUnavailable))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Text(capabilitySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                }
            }
            .accessibilityLabel(APCLocalization.format(
                .connectionsCapabilitiesAccessibilityFormat,
                capabilitySummary
            ))
            .accessibilityIdentifier("connections.detail.capabilities-disclosure")
        }
        .accessibilityIdentifier("connections.detail.capabilities")
    }

    private var capabilitySummary: String {
        guard capabilities.hasReportedCapabilities else {
            return APCLocalization.text(.connectionsCapabilitiesUnreported)
        }
        let version = capabilities.contractVersion.isEmpty
            ? APCLocalization.text(.connectionsCapabilitiesVersionUnreported)
            : capabilities.contractVersion
        return APCLocalization.format(
            .connectionsCapabilitiesSummaryFormat,
            version,
            capabilities.auditedEvents.count,
            capabilities.subscribedEvents.count
        )
    }

    private func capabilityList(title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(APCLocalization.format(
                .connectionsCapabilitiesListFormat,
                title,
                values.count
            ))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if values.isEmpty {
                Text(APCLocalization.text(.connectionsCapabilitiesUnreported))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 3, height: 3)
                            .accessibilityHidden(true)
                        Text(value)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

struct ConnectionEnvironmentInspector: View {
    @EnvironmentObject private var store: AppStore
    let source: AgentSource
    let status: AgentConnectionStatus?

    private var busy: Bool {
        store.connectionOperationState.isRunning
    }

    private var runtimeInfo: PetCoreRuntimeInfo {
        store.petCoreRuntimeInfo
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(APCLocalization.text(.connectionsEnvironmentTitle))
                    .font(.headline)
                Text(source.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.connectionCheckCWD ?? APCLocalization.text(.connectionsDefaultHome))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(APCLocalization.text(.connectionsDirectoryDetail))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        store.chooseConnectionCheckDirectory()
                    } label: {
                        Label(APCLocalization.text(.connectionsChooseDirectory), systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                    .accessibilityIdentifier("connections.inspector.directory.choose")

                    if store.connectionCheckCWD != nil {
                        Button(APCLocalization.text(.connectionsResetDirectory)) {
                            store.resetConnectionCheckDirectory()
                        }
                        .buttonStyle(.borderless)
                        .disabled(busy)
                        .accessibilityIdentifier("connections.inspector.directory.reset")
                    }
                } header: {
                    Text(APCLocalization.text(.connectionsProjectDirectory))
                }

                Section {
                    InspectorValueRow(
                        title: APCLocalization.text(.technicalPetCore),
                        value: runtimeInfo.version ?? APCLocalization.text(.commonNotReported)
                    )
                    InspectorValueRow(
                        title: APCLocalization.text(.technicalRPC),
                        value: runtimeInfo.rpcProtocol ?? APCLocalization.text(.commonNotReported)
                    )
                    InspectorValueRow(
                        title: APCLocalization.text(.technicalSchema),
                        value: runtimeInfo.databaseSchemaRange
                            ?? APCLocalization.text(.commonNotReported)
                    )
                    InspectorValueRow(
                        title: APCLocalization.text(.technicalAppBuild),
                        value: runtimeInfo.appBuild ?? APCLocalization.text(.commonNotReported)
                    )
                    InspectorValueRow(
                        title: APCLocalization.text(.technicalBuildID),
                        value: runtimeInfo.buildID ?? APCLocalization.text(.commonNotReported)
                    )
                    InspectorValueRow(
                        title: APCLocalization.text(.connectionsInstanceID),
                        value: runtimeInfo.instanceID ?? APCLocalization.text(.commonNotReported)
                    )
                } header: {
                    Text(APCLocalization.text(.connectionsRuntimeIdentity))
                } footer: {
                    Text(APCLocalization.text(.connectionsRuntimeFooter))
                }

                Section {
                    DisclosureGroup {
                        if let status, !status.installPaths.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(status.installPaths, id: \.self) { path in
                                    Text(path)
                                        .font(.caption2.monospaced())
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.top, 6)
                        } else {
                            Text(APCLocalization.text(.connectionsInstallLocationsEmpty))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                        }
                    } label: {
                        Text(APCLocalization.format(
                            .connectionsInstallLocationsFormat,
                            status?.installPaths.count ?? 0
                        ))
                    }
                    .accessibilityIdentifier("connections.inspector.install-paths")
                } header: {
                    Text(APCLocalization.text(.connectionsInstallLocationTitle))
                }

                Section {
                    Label(
                        APCLocalization.text(.connectionsPrivacyDetail),
                        systemImage: "hand.raised.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("connections.inspector.privacy")
                } header: {
                    Text(APCLocalization.text(.connectionsPrivacyTitle))
                }
            }
            .formStyle(.grouped)
        }
        .accessibilityIdentifier("connections.inspector")
    }
}

private struct InspectorValueRow: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(APCLocalization.format(
            .connectionsInspectorValueFormat,
            title,
            value
        ))
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
