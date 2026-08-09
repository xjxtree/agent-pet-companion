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

/// Keeps the one-point rhythm formerly occupied by a separator without
/// drawing a line or exposing an accessibility element.
struct LayoutPreservingHorizontalSeparatorGap: View {
    var body: some View {
        Color.clear
            .frame(height: 1)
            .accessibilityHidden(true)
    }
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
        case .thinking, .tool:
            self = .checking
        case .waiting:
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
        .accessibilityElement(children: .contain)
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

extension AgentTaskVerificationState {
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
enum SessionBubbleRowPresentation {
    case detailed
    case standaloneSummary
}

/// A compact, closed status vocabulary for standalone session cards. Running
/// states stay visually neutral; only terminal or user-attention states add a
/// symbol, with no accessory button, capsule, or second card boundary.
enum SessionBubbleRowStateIndicator: String, Equatable {
    case needsInput
    case done
    case failed

    init?(eventType: AgentEventKind?) {
        switch eventType {
        case .waiting:
            self = .needsInput
        case .done:
            self = .done
        case .failed:
            self = .failed
        case .start, .thinking, .plan, .tool, nil:
            return nil
        }
    }

    var systemImage: String {
        switch self {
        case .needsInput: "exclamationmark.circle.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .needsInput: .orange
        case .done: .green
        case .failed: .red
        }
    }
}

struct SessionBubbleRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.overlayBubbleFontScale) private var fontScale

    var session: OverlaySessionContent
    var action: () -> Void
    var dismissAction: (() -> Void)?
    var presentation: SessionBubbleRowPresentation
    var agentName: String?
    var reservedTrailingAccessoryWidth: CGFloat
    var primaryActionLabel: String?
    @State private var hovered = false
    @FocusState private var focused: Bool

    init(
        session: OverlaySessionContent,
        action: @escaping () -> Void,
        dismissAction: (() -> Void)? = nil,
        presentation: SessionBubbleRowPresentation = .detailed,
        agentName: String? = nil,
        reservedTrailingAccessoryWidth: CGFloat = 0,
        primaryActionLabel: String? = nil
    ) {
        self.session = session
        self.action = action
        self.dismissAction = dismissAction
        self.presentation = presentation
        self.agentName = agentName
        self.reservedTrailingAccessoryWidth = reservedTrailingAccessoryWidth
        self.primaryActionLabel = primaryActionLabel
    }

    var body: some View {
        Button(action: action) {
            rowContent
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("overlay.session.\(session.id)")
        .accessibilityLabel(session.accessibilityLabel)
        .modifier(SessionBubbleAccessibilityActions(
            openLabel: primaryActionLabel ?? session.actionLabel,
            closeLabel: dismissAction == nil
                ? nil
                : APCLocalization.text(.overlayDismissSession),
            onOpen: action,
            onClose: dismissAction
        ))
        .help(helpText)
    }

    private var rowContent: some View {
        Group {
            switch presentation {
            case .detailed:
                detailedTextContent
            case .standaloneSummary:
                standaloneSummaryContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, OverlayGeometry.bubbleSessionHorizontalPadding)
        .padding(.vertical, OverlayGeometry.bubbleSessionVerticalPadding)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background {
            switch presentation {
            case .detailed:
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill((statusColor ?? .clear).opacity(0.12))

                    if hovered || focused {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    }
                }
            case .standaloneSummary:
                // The card already owns one full glass surface. Keeping this
                // row transparent avoids a second rounded status/hover layer
                // that reads as nested borders in the flat session tray.
                Color.clear
            }
        }
    }

    private var standaloneSummaryContent: some View {
        VStack(alignment: .leading, spacing: OverlayGeometry.bubbleStandaloneMetadataSpacing) {
            standaloneIdentityLine
                .padding(.trailing, reservedTrailingAccessoryWidth)

            standaloneSummaryText
                .lineLimit(
                    OverlayGeometry.bubbleStandaloneSummaryLineLimit,
                    reservesSpace: true
                )
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(
                    height: OverlayGeometry.bubbleStandaloneSummaryTextHeight(
                        fontScale: fontScale
                    ),
                    alignment: .topLeading
                )
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var standaloneIdentityLine: some View {
        HStack(alignment: .center, spacing: 5) {
            if let source = session.source {
                AgentIconView(
                    source: source,
                    size: OverlayGeometry.bubbleHeaderAvatarWidth
                )
                .accessibilityHidden(true)
            }

            if let agentName = resolvedStandaloneAgentName {
                Text(agentName)
                    .font(OverlayBubbleTypography.font(
                        .caption1,
                        weight: .semibold,
                        scale: fontScale
                    ))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }

            if let surfaceLabel = session.surfaceLabel {
                Text("· \(surfaceLabel)")
                    .font(OverlayBubbleTypography.font(
                        .caption2,
                        weight: .medium,
                        scale: fontScale
                    ))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 8)

            if let stateIndicator {
                Image(systemName: stateIndicator.systemImage)
                    .font(OverlayBubbleTypography.font(
                        .caption1,
                        weight: .semibold,
                        scale: fontScale
                    ))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(stateIndicator.color)
                    .frame(
                        width: OverlayBubbleTypography.scaledControlMetric(
                            15,
                            scale: fontScale
                        ),
                        height: OverlayBubbleTypography.scaledControlMetric(
                            15,
                            scale: fontScale
                        )
                    )
                    .help(session.statusText)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier(
                        "overlay.session.status.\(stateIndicator.rawValue)"
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resolvedStandaloneAgentName: String? {
        let resolved = (agentName ?? session.source?.title)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return resolved?.isEmpty == false ? resolved : nil
    }

    private var standaloneSummaryText: Text {
        let title = Text(session.sessionTitle)
            .font(OverlayBubbleTypography.font(
                .callout,
                weight: .semibold,
                scale: fontScale
            ))
            .foregroundColor(.primary)
        guard !session.standaloneSummaryText.isEmpty else { return title }
        return title
            + Text(" · ")
                .font(OverlayBubbleTypography.font(
                    .callout,
                    weight: .medium,
                    scale: fontScale
                ))
                .foregroundColor(.secondary)
            + Text(session.standaloneSummaryText)
                .font(OverlayBubbleTypography.font(
                    .callout,
                    weight: .regular,
                    scale: fontScale
                ))
                .foregroundColor(.secondary)
    }

    private var detailedTextContent: some View {
        VStack(alignment: .leading, spacing: OverlayGeometry.bubbleSessionTitleSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.sessionTitle)
                    .font(OverlayBubbleTypography.font(
                        .callout,
                        weight: .semibold,
                        scale: fontScale
                    ))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let surfaceLabel = session.surfaceLabel {
                    Text(surfaceLabel)
                        .font(OverlayBubbleTypography.font(
                            .caption2,
                            weight: .medium,
                            scale: fontScale
                        ))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(0.12))
                        )
                }

                Spacer(minLength: 8)

                if !session.statusText.isEmpty {
                    Text(session.statusText)
                        .font(OverlayBubbleTypography.font(
                            .caption2,
                            weight: .semibold,
                            scale: fontScale
                        ))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill((statusColor ?? .clear).opacity(0.24))
                        )
                        .overlay {
                            Capsule()
                                .stroke((statusColor ?? .clear).opacity(0.62), lineWidth: 0.75)
                                .allowsHitTesting(false)
                        }
                }

                destinationIndicator
            }
            .frame(
                height: OverlayGeometry.bubbleDetailedHeaderHeight(fontScale: fontScale),
                alignment: .top
            )

            VStack(alignment: .leading, spacing: 0) {
                Text(session.primaryDetailText)
                    .font(OverlayBubbleTypography.font(
                        .caption1,
                        weight: .semibold,
                        scale: fontScale
                    ))
                    .foregroundStyle(Color.primary)
                    .lineLimit(
                        session.secondaryDetailText == nil
                            ? OverlayGeometry.bubbleDetailLineLimit
                            : 1,
                        reservesSpace: session.secondaryDetailText == nil
                    )
                    .truncationMode(.tail)

                if let secondaryDetailText = session.secondaryDetailText {
                    Text(secondaryDetailText)
                        .font(OverlayBubbleTypography.font(
                            .caption1,
                            weight: .medium,
                            scale: fontScale
                        ))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(
                height: OverlayGeometry.bubbleDetailTextHeight(fontScale: fontScale),
                alignment: .topLeading
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Every row reserves one trailing affordance slot. Hover/focus reveals
    /// either the destination arrow or an explicit unavailable indicator.
    private var destinationIndicator: some View {
        Image(systemName: session.canOpen
            ? "arrow.up.forward"
            : "exclamationmark.circle")
            .font(OverlayBubbleTypography.font(
                .caption2,
                weight: .bold,
                scale: fontScale
            ))
            .foregroundStyle(session.canOpen ? Color.primary : Color.secondary)
            .frame(width: OverlayBubbleTypography.scaledControlMetric(
                9,
                scale: fontScale
            ))
            .opacity(hovered || focused ? 1 : 0)
            .animation(
                reduceMotion
                    ? nil
                    : .easeOut(duration: OverlayMotion.controlFadeDuration),
                value: hovered || focused
            )
            .accessibilityHidden(true)
    }

    private var helpText: String {
        if let primaryActionLabel {
            return primaryActionLabel
        }
        guard session.canOpen else {
            return APCLocalization.text(.overlayHelpUnavailable)
        }
        if session.dismissesAfterActivation {
            return APCLocalization.text(.overlayHelpOpenAndDismiss)
        }
        return APCLocalization.text(.overlayHelpOpen)
    }

    private var statusColor: Color? {
        SessionBubbleRowStateIndicator(eventType: session.eventType)?.color
    }

    private var stateIndicator: SessionBubbleRowStateIndicator? {
        SessionBubbleRowStateIndicator(eventType: session.eventType)
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
    @State private var isHeaderHovered = false
    @FocusState private var isHeaderFocused: Bool

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
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 12, height: 20)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)

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

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(
                        cornerRadius: SharedProductComponentLayout.cornerRadius - 4,
                        style: .continuous
                    )
                    .fill(
                        Color.primary.opacity(
                            isHeaderHovered || isHeaderFocused ? 0.05 : 0
                        )
                    )
                    .allowsHitTesting(false)
                }
                .focused($isHeaderFocused)
                .onHover { isHeaderHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHeaderHovered)
                .animation(.easeOut(duration: 0.12), value: isHeaderFocused)
                .accessibilityLabel(title)
                .accessibilityValue(APCLocalization.text(
                    isExpanded ? .commonExpanded : .commonCollapsed
                ))
                .accessibilityHint(APCLocalization.text(
                    isExpanded
                        ? .commonCollapseDisclosureHint
                        : .commonExpandDisclosureHint
                ))

                if isExpanded {
                    Divider()
                        .padding(.top, 10)

                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                        .transition(.opacity.combined(with: .move(edge: .top)))
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
        .apcClearGlassButtonStyle(prominent: true)
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
        .apcClearGlassButtonStyle()
        .controlSize(.regular)
        .disabled(!presentation.isEnabled)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityHint(presentation.accessibilityHint ?? "")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct ProductStatusIndicator: View {
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

struct ProductCardSurface<Content: View>: View {
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
