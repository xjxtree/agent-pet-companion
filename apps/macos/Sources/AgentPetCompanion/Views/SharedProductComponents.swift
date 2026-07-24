import AgentPetCompanionCore
import SwiftUI

/// Stable component names shared by the five control-center pages.
///
/// Page-specific presentation models provide the scope/instance identity. The
/// component type remains part of the identifier, so a page can compose the
/// full shared set without collisions.
enum SharedProductComponentKind: String, CaseIterable {
    case pageHeader = "page-header"
    case primaryExperienceCard = "primary-experience-card"
    case petPreviewStage = "pet-preview-stage"
    case agentHealthRow = "agent-health-row"
    case attentionPresetPicker = "attention-preset-picker"
    case advancedDetailsDisclosure = "advanced-details-disclosure"
    case emptyStateAction = "empty-state-action"
    case inlineRecoveryBanner = "inline-recovery-banner"
}

struct ProductComponentIdentity: Hashable {
    let scope: String
    let instance: String?

    init(scope: String, instance: String? = nil) {
        precondition(Self.isValidSegment(scope), "Invalid product component scope")
        precondition(
            instance.map(Self.isValidSegment) ?? true,
            "Invalid product component instance"
        )
        self.scope = scope
        self.instance = instance
    }

    func accessibilityIdentifier(
        for kind: SharedProductComponentKind,
        suffix: String? = nil
    ) -> String {
        let segments = [
            "product",
            scope,
            instance,
            kind.rawValue,
            suffix,
        ].compactMap { $0 }
        return segments.joined(separator: ".")
    }

    private static func isValidSegment(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                true
            default:
                false
            }
        }
    }
}

enum SharedProductComponentLayout {
    /// The detail column remains usable after the main navigation consumes its
    /// width at the smallest supported control-center window size.
    static let supportedMinimumContentWidth: CGFloat = 360
    static let pageSpacing: CGFloat = 18
    static let cardSpacing: CGFloat = 14
    static let rowSpacing: CGFloat = 10
    static let cardPadding: CGFloat = 20
    static let compactPadding: CGFloat = 16
    static let cornerRadius: CGFloat = 14
    static let previewMinimumHeight: CGFloat = 220
}

/// A closed visual vocabulary. Low-level check strings and arbitrary payloads
/// never decide status color, progress, or action authority.
enum ProductStatusAppearance: String, CaseIterable {
    case neutral
    case normal
    case attention
    case error
    case checking

    init(lifecycle: ProductLifecycleState) {
        switch lifecycle {
        case .idle, .done:
            self = .normal
        case .start, .tool:
            self = .checking
        case .waiting, .review:
            self = .attention
        case .failed:
            self = .error
        }
    }

    init(connectionHealth: AgentConnectionHealthState) {
        switch connectionHealth {
        case .notChecked:
            self = .neutral
        case .checking:
            self = .checking
        case .connected:
            self = .normal
        case .needsRepair:
            self = .attention
        case .unavailable:
            self = .error
        }
    }
}

struct ProductStatusPresentation: Hashable {
    let appearance: ProductStatusAppearance
    let title: String
    let detail: String?

    init(
        appearance: ProductStatusAppearance,
        title: String,
        detail: String? = nil
    ) {
        self.appearance = appearance
        self.title = title
        self.detail = detail
    }

    init(
        lifecycle: ProductLifecycleState,
        title: String,
        detail: String? = nil
    ) {
        self.init(
            appearance: ProductStatusAppearance(lifecycle: lifecycle),
            title: title,
            detail: detail
        )
    }

    init(
        connectionHealth: AgentConnectionHealthState,
        title: String,
        detail: String? = nil
    ) {
        self.init(
            appearance: ProductStatusAppearance(connectionHealth: connectionHealth),
            title: title,
            detail: detail
        )
    }
}

/// Display metadata stays paired with the semantic action value. Views invoke
/// `action`, never infer a mutation from `title` or `accessibilityLabel`.
struct ProductActionPresentation<Action: Hashable>: Hashable {
    let action: Action
    let title: String
    let systemImage: String?
    let accessibilityLabel: String
    let accessibilityHint: String?
    let isEnabled: Bool

    init(
        action: Action,
        title: String,
        systemImage: String? = nil,
        accessibilityLabel: String? = nil,
        accessibilityHint: String? = nil,
        isEnabled: Bool = true
    ) {
        self.action = action
        self.title = title
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel ?? title
        self.accessibilityHint = accessibilityHint
        self.isEnabled = isEnabled
    }
}

struct AttentionPresetOption: Identifiable, Hashable {
    let preset: AttentionPreset
    let title: String
    let detail: String
    let isSelectable: Bool

    var id: AttentionPreset { preset }

    init(
        preset: AttentionPreset,
        title: String,
        detail: String,
        isSelectable: Bool? = nil
    ) {
        self.preset = preset
        self.title = title
        self.detail = detail
        self.isSelectable = isSelectable ?? (preset != .custom)
    }
}

enum SharedProductComponentText {
    static func distinctDetail(
        _ detail: String?,
        comparedTo primaryValues: [String]
    ) -> String? {
        guard let detail else { return nil }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let repeatsPrimaryValue = primaryValues.contains { primaryValue in
            primaryValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ) == normalized
        }
        return repeatsPrimaryValue ? nil : trimmed
    }
}

struct ProductPageHeader: View {
    let identity: ProductComponentIdentity
    let title: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)

            Text(summary)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            identity.accessibilityIdentifier(for: .pageHeader)
        )
    }
}

struct PrimaryExperienceCard<Action: Hashable, Content: View>: View {
    let identity: ProductComponentIdentity
    let title: String
    let summary: String
    let status: ProductStatusPresentation?
    let primaryAction: ProductActionPresentation<Action>?
    let onPrimaryAction: (Action) -> Void
    @ViewBuilder let content: Content

    init(
        identity: ProductComponentIdentity,
        title: String,
        summary: String,
        status: ProductStatusPresentation? = nil,
        primaryAction: ProductActionPresentation<Action>? = nil,
        onPrimaryAction: @escaping (Action) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.identity = identity
        self.title = title
        self.summary = summary
        self.status = status
        self.primaryAction = primaryAction
        self.onPrimaryAction = onPrimaryAction
        self.content = content()
    }

    var body: some View {
        ProductCardSurface {
            VStack(alignment: .leading, spacing: SharedProductComponentLayout.cardSpacing) {
                headingAndAction

                Text(summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let status {
                    ProductStatusIndicator(presentation: status)
                }

                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier(
            identity.accessibilityIdentifier(for: .primaryExperienceCard)
        )
    }

    @ViewBuilder
    private var headingAndAction: some View {
        if let primaryAction {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    heading
                    Spacer(minLength: 12)
                    ProductPrimaryActionButton(
                        presentation: primaryAction,
                        accessibilityIdentifier: identity.accessibilityIdentifier(
                            for: .primaryExperienceCard,
                            suffix: "primary-action"
                        ),
                        perform: onPrimaryAction
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    heading
                    ProductPrimaryActionButton(
                        presentation: primaryAction,
                        accessibilityIdentifier: identity.accessibilityIdentifier(
                            for: .primaryExperienceCard,
                            suffix: "primary-action"
                        ),
                        perform: onPrimaryAction
                    )
                }
            }
        } else {
            heading
        }
    }

    private var heading: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct PetPreviewStage<Content: View>: View {
    let identity: ProductComponentIdentity
    let accessibilityLabel: String
    let minimumHeight: CGFloat
    @ViewBuilder let content: Content

    init(
        identity: ProductComponentIdentity,
        accessibilityLabel: String,
        minimumHeight: CGFloat = SharedProductComponentLayout.previewMinimumHeight,
        @ViewBuilder content: () -> Content
    ) {
        self.identity = identity
        self.accessibilityLabel = accessibilityLabel
        self.minimumHeight = minimumHeight
        self.content = content()
    }

    var body: some View {
        content
            .frame(
                minWidth: 0,
                maxWidth: .infinity,
                minHeight: minimumHeight,
                alignment: .center
            )
            .background(Color(nsColor: .textBackgroundColor), in: previewShape)
            .clipShape(previewShape)
            .overlay {
                previewShape
                    .stroke(APCDesign.stroke.opacity(0.72), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(
                identity.accessibilityIdentifier(for: .petPreviewStage)
            )
    }

    private var previewShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: SharedProductComponentLayout.cornerRadius,
            style: .continuous
        )
    }
}

struct AgentHealthRow: View {
    let identity: ProductComponentIdentity
    let agentTitle: String
    let agentSummary: String?
    let health: AgentConnectionHealthState
    let healthTitle: String
    let taskVerification: AgentTaskVerificationState?
    let taskVerificationTitle: String?
    let taskVerificationDetail: String?
    let primaryAction: ProductActionPresentation<AgentConnectionPrimaryAction>?
    let onPrimaryAction: (AgentConnectionPrimaryAction) -> Void

    init(
        identity: ProductComponentIdentity,
        agentTitle: String,
        agentSummary: String? = nil,
        health: AgentConnectionHealthState,
        healthTitle: String,
        taskVerification: AgentTaskVerificationState? = nil,
        taskVerificationTitle: String? = nil,
        taskVerificationDetail: String? = nil,
        primaryAction: ProductActionPresentation<AgentConnectionPrimaryAction>? = nil,
        onPrimaryAction: @escaping (AgentConnectionPrimaryAction) -> Void
    ) {
        self.identity = identity
        self.agentTitle = agentTitle
        self.agentSummary = agentSummary
        self.health = health
        self.healthTitle = healthTitle
        self.taskVerification = taskVerification
        self.taskVerificationTitle = taskVerificationTitle
        self.taskVerificationDetail = taskVerificationDetail
        self.primaryAction = primaryAction
        self.onPrimaryAction = onPrimaryAction
    }

    var body: some View {
        ProductCardSurface(padding: SharedProductComponentLayout.compactPadding) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: SharedProductComponentLayout.rowSpacing) {
                    agentIdentity
                    Spacer(minLength: 12)
                    statusIndicators
                    actionButton
                }

                VStack(alignment: .leading, spacing: SharedProductComponentLayout.rowSpacing) {
                    agentIdentity
                    statusIndicators
                    actionButton
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            identity.accessibilityIdentifier(for: .agentHealthRow)
        )
    }

    private var agentIdentity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(agentTitle)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let agentSummary {
                Text(agentSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var healthIndicator: some View {
        ProductStatusIndicator(
            presentation: ProductStatusPresentation(
                connectionHealth: health,
                title: healthTitle
            )
        )
    }

    private var statusIndicators: some View {
        VStack(alignment: .leading, spacing: 6) {
            healthIndicator
            taskVerificationIndicator
        }
    }

    @ViewBuilder
    private var taskVerificationIndicator: some View {
        if let taskVerification, let taskVerificationTitle {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: taskVerification.systemImage)
                    .foregroundStyle(taskVerification.color)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(taskVerificationTitle)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(taskVerification.color)
                        .fixedSize(horizontal: false, vertical: true)
                    if let taskVerificationDetail {
                        Text(taskVerificationDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(taskVerificationTitle)
            .accessibilityValue(taskVerificationDetail ?? "")
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if let primaryAction,
           primaryAction.action != .unavailable
        {
            ProductSecondaryActionButton(
                presentation: primaryAction,
                accessibilityIdentifier: identity.accessibilityIdentifier(
                    for: .agentHealthRow,
                    suffix: "primary-action"
                ),
                perform: onPrimaryAction
            )
        }
    }
}

private extension AgentTaskVerificationState {
    var color: Color {
        switch self {
        case .notRun:
            APCDesign.textSecondary
        case .awaitingTask:
            APCDesign.warning
        case .verified:
            APCDesign.success
        }
    }

    var systemImage: String {
        switch self {
        case .notRun:
            "circle.dashed"
        case .awaitingTask:
            "clock.badge.questionmark"
        case .verified:
            "checkmark.seal.fill"
        }
    }
}

/// The single production session row used by the desktop conversation bubble.
///
/// Navigation authority and accessibility copy come from the same validated
/// `OverlaySessionContent`, so exact-session, Agent-host, and unavailable
/// destinations cannot drift into separate visual and assistive behaviors.
struct SessionBubbleRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var session: OverlaySessionContent
    var action: () -> Void
    var dismissAction: (() -> Void)?
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if session.canOpen {
                Button(action: action) {
                    rowContent
                }
                .buttonStyle(.plain)
                .focused($focused)
            } else {
                rowContent
            }
        }
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("overlay.session.\(session.id)")
        .accessibilityLabel(session.accessibilityLabel)
        .modifier(SessionBubbleAccessibilityActions(
            openLabel: session.canOpen ? session.actionLabel : nil,
            closeLabel: dismissAction == nil
                ? nil
                : APCLocalization.text(.overlayDismissSession),
            onOpen: action,
            onClose: dismissAction
        ))
        .help(helpText)
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: OverlayGeometry.bubbleSessionTitleSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.sessionTitle)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                if !session.statusText.isEmpty {
                    Text(session.statusText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(statusColor.opacity(0.24))
                        )
                        .overlay {
                            Capsule()
                                .stroke(statusColor.opacity(0.62), lineWidth: 0.75)
                                .allowsHitTesting(false)
                        }
                }

                if session.canOpen {
                    Image(systemName: "arrow.up.forward")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 9)
                        .opacity(hovered || focused ? 1 : 0)
                        .animation(
                            reduceMotion
                                ? nil
                                : .easeOut(duration: OverlayMotion.controlFadeDuration),
                            value: hovered || focused
                        )
                        .accessibilityHidden(true)
                }
            }

            Text(session.messageText)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.primary)
                .lineLimit(OverlayGeometry.bubbleDetailLineLimit)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, OverlayGeometry.bubbleSessionHorizontalPadding)
        .padding(.vertical, OverlayGeometry.bubbleSessionVerticalPadding)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    (hovered || focused) && session.canOpen
                        ? Color.primary.opacity(0.05)
                        : .clear
                )
        )
    }

    private var helpText: String {
        if session.dismissesAfterActivation {
            return APCLocalization.text(
                session.canOpen ? .overlayHelpOpenAndDismiss : .overlayHelpDismiss
            )
        }
        return APCLocalization.text(
            session.canOpen ? .overlayHelpOpen : .overlayHelpUnavailable
        )
    }

    private var statusColor: Color {
        switch session.eventType {
        case .waiting, .review: .orange
        case .failed: .red
        case .done: .green
        case .start, .tool: .blue
        case nil: .secondary
        }
    }
}

private struct SessionBubbleAccessibilityActions: ViewModifier {
    var openLabel: String?
    var closeLabel: String?
    var onOpen: () -> Void
    var onClose: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let openLabel, let closeLabel, let onClose {
            content
                .accessibilityAction(named: openLabel) { onOpen() }
                .accessibilityAction(named: closeLabel) { onClose() }
        } else if let openLabel {
            content.accessibilityAction(named: openLabel) { onOpen() }
        } else if let closeLabel, let onClose {
            content.accessibilityAction(named: closeLabel) { onClose() }
        } else {
            content
        }
    }
}

struct AttentionPresetPicker: View {
    let identity: ProductComponentIdentity
    let title: String
    let selection: AttentionPreset
    let options: [AttentionPresetOption]
    let onSelection: (AttentionPreset) -> Void

    init(
        identity: ProductComponentIdentity,
        title: String,
        selection: AttentionPreset,
        options: [AttentionPresetOption],
        onSelection: @escaping (AttentionPreset) -> Void
    ) {
        precondition(
            Set(options.map(\.preset)).count == options.count,
            "Attention preset options must be unique"
        )
        self.identity = identity
        self.title = title
        self.selection = selection
        self.options = options
        self.onSelection = onSelection
    }

    var body: some View {
        ProductCardSurface(padding: SharedProductComponentLayout.compactPadding) {
            VStack(alignment: .leading, spacing: SharedProductComponentLayout.rowSpacing) {
                Picker(title, selection: selectionBinding) {
                    ForEach(options) { option in
                        Text(option.title)
                            .fixedSize(horizontal: false, vertical: true)
                            .tag(option.preset)
                            .disabled(!option.isSelectable)
                            .accessibilityIdentifier(
                                identity.accessibilityIdentifier(
                                    for: .attentionPresetPicker,
                                    suffix: "option-\(option.preset.rawValue)"
                                )
                            )
                    }
                }
                .pickerStyle(.radioGroup)

                if let selectedOption {
                    Text(selectedOption.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier(
            identity.accessibilityIdentifier(for: .attentionPresetPicker)
        )
    }

    private var selectedOption: AttentionPresetOption? {
        options.first { $0.preset == selection }
    }

    private var selectionBinding: Binding<AttentionPreset> {
        Binding(
            get: { selection },
            set: { nextSelection in
                guard options.first(where: { $0.preset == nextSelection })?.isSelectable == true
                else { return }
                onSelection(nextSelection)
            }
        )
    }
}

struct AdvancedDetailsDisclosure<Content: View>: View {
    let identity: ProductComponentIdentity
    let title: String
    let summary: String?
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    init(
        identity: ProductComponentIdentity,
        title: String,
        summary: String? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.identity = identity
        self.title = title
        self.summary = summary
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        ProductCardSurface(padding: SharedProductComponentLayout.compactPadding) {
            DisclosureGroup(isExpanded: $isExpanded) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let summary {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityIdentifier(
            identity.accessibilityIdentifier(for: .advancedDetailsDisclosure)
        )
    }
}

struct EmptyStateAction<Action: Hashable>: View {
    let identity: ProductComponentIdentity
    let status: ProductStatusPresentation
    let message: String
    let primaryAction: ProductActionPresentation<Action>?
    let onPrimaryAction: (Action) -> Void

    init(
        identity: ProductComponentIdentity,
        status: ProductStatusPresentation,
        message: String,
        primaryAction: ProductActionPresentation<Action>? = nil,
        onPrimaryAction: @escaping (Action) -> Void
    ) {
        self.identity = identity
        self.status = status
        self.message = message
        self.primaryAction = primaryAction
        self.onPrimaryAction = onPrimaryAction
    }

    var body: some View {
        ProductCardSurface {
            VStack(alignment: .center, spacing: SharedProductComponentLayout.cardSpacing) {
                ProductStatusIndicator(presentation: status)

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let primaryAction {
                    ProductPrimaryActionButton(
                        presentation: primaryAction,
                        accessibilityIdentifier: identity.accessibilityIdentifier(
                            for: .emptyStateAction,
                            suffix: "primary-action"
                        ),
                        perform: onPrimaryAction
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            identity.accessibilityIdentifier(for: .emptyStateAction)
        )
    }
}

struct InlineRecoveryBanner<Action: Hashable>: View {
    let identity: ProductComponentIdentity
    let status: ProductStatusPresentation
    let primaryAction: ProductActionPresentation<Action>?
    let onPrimaryAction: (Action) -> Void

    init(
        identity: ProductComponentIdentity,
        status: ProductStatusPresentation,
        primaryAction: ProductActionPresentation<Action>? = nil,
        onPrimaryAction: @escaping (Action) -> Void
    ) {
        self.identity = identity
        self.status = status
        self.primaryAction = primaryAction
        self.onPrimaryAction = onPrimaryAction
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: SharedProductComponentLayout.rowSpacing) {
                ProductStatusIndicator(presentation: status)
                Spacer(minLength: 12)
                actionButton
            }

            VStack(alignment: .leading, spacing: SharedProductComponentLayout.rowSpacing) {
                ProductStatusIndicator(presentation: status)
                actionButton
            }
        }
        .padding(SharedProductComponentLayout.compactPadding)
        .background(status.appearance.color.opacity(0.08), in: bannerShape)
        .overlay {
            bannerShape
                .stroke(status.appearance.color.opacity(0.34), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            identity.accessibilityIdentifier(for: .inlineRecoveryBanner)
        )
    }

    @ViewBuilder
    private var actionButton: some View {
        if let primaryAction {
            ProductPrimaryActionButton(
                presentation: primaryAction,
                accessibilityIdentifier: identity.accessibilityIdentifier(
                    for: .inlineRecoveryBanner,
                    suffix: "primary-action"
                ),
                perform: onPrimaryAction
            )
        }
    }

    private var bannerShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: SharedProductComponentLayout.cornerRadius,
            style: .continuous
        )
    }
}

struct ProductActionLabel: View {
    let title: String
    let systemImage: String?

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout.weight(.semibold))
        .multilineTextAlignment(.center)
    }
}

private struct ProductPrimaryActionButton<Action: Hashable>: View {
    let presentation: ProductActionPresentation<Action>
    let accessibilityIdentifier: String
    let perform: (Action) -> Void

    var body: some View {
        Button {
            perform(presentation.action)
        } label: {
            ProductActionLabel(
                title: presentation.title,
                systemImage: presentation.systemImage
            )
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(!presentation.isEnabled)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityHint(presentation.accessibilityHint ?? "")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct ProductSecondaryActionButton<Action: Hashable>: View {
    let presentation: ProductActionPresentation<Action>
    let accessibilityIdentifier: String
    let perform: (Action) -> Void

    var body: some View {
        Button {
            perform(presentation.action)
        } label: {
            ProductActionLabel(
                title: presentation.title,
                systemImage: presentation.systemImage
            )
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(!presentation.isEnabled)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityHint(presentation.accessibilityHint ?? "")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct ProductStatusIndicator: View {
    let presentation: ProductStatusPresentation

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if presentation.appearance == .checking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: presentation.appearance.systemImage)
                    .foregroundStyle(presentation.appearance.color)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(presentation.appearance.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = presentation.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.title)
        .accessibilityValue(presentation.detail ?? "")
    }
}

private struct ProductCardSurface<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let padding: CGFloat
    @ViewBuilder let content: Content

    init(
        padding: CGFloat = SharedProductComponentLayout.cardPadding,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(APCDesign.panel, in: shape)
            .overlay {
                shape
                    .stroke(
                        APCDesign.stroke.opacity(
                            colorSchemeContrast == .increased ? 1 : 0.72
                        ),
                        lineWidth: colorSchemeContrast == .increased ? 2 : 1
                    )
                    .allowsHitTesting(false)
            }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: SharedProductComponentLayout.cornerRadius,
            style: .continuous
        )
    }
}

private extension ProductStatusAppearance {
    var color: Color {
        switch self {
        case .neutral:
            APCDesign.textSecondary
        case .normal:
            APCDesign.textSecondary
        case .attention:
            APCDesign.warning
        case .error:
            APCDesign.destructive
        case .checking:
            APCDesign.accent
        }
    }

    var systemImage: String {
        switch self {
        case .neutral:
            "circle.dashed"
        case .normal:
            "checkmark.circle"
        case .attention:
            "exclamationmark.circle.fill"
        case .error:
            "xmark.octagon.fill"
        case .checking:
            "hourglass"
        }
    }
}
