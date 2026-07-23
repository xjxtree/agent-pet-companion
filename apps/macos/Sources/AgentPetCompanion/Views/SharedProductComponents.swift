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
    case sessionBubbleRow = "session-bubble-row"
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
            .background(.thinMaterial, in: previewShape)
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
    let primaryAction: ProductActionPresentation<AgentConnectionPrimaryAction>?
    let onPrimaryAction: (AgentConnectionPrimaryAction) -> Void

    init(
        identity: ProductComponentIdentity,
        agentTitle: String,
        agentSummary: String? = nil,
        health: AgentConnectionHealthState,
        healthTitle: String,
        primaryAction: ProductActionPresentation<AgentConnectionPrimaryAction>? = nil,
        onPrimaryAction: @escaping (AgentConnectionPrimaryAction) -> Void
    ) {
        self.identity = identity
        self.agentTitle = agentTitle
        self.agentSummary = agentSummary
        self.health = health
        self.healthTitle = healthTitle
        self.primaryAction = primaryAction
        self.onPrimaryAction = onPrimaryAction
    }

    var body: some View {
        ProductCardSurface(padding: SharedProductComponentLayout.compactPadding) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: SharedProductComponentLayout.rowSpacing) {
                    agentIdentity
                    Spacer(minLength: 12)
                    healthIndicator
                    actionButton
                }

                VStack(alignment: .leading, spacing: SharedProductComponentLayout.rowSpacing) {
                    agentIdentity
                    healthIndicator
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

    @ViewBuilder
    private var actionButton: some View {
        if let primaryAction,
           primaryAction.action != .unavailable
        {
            ProductPrimaryActionButton(
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

/// The overlay already owns a private `SessionBubbleRow`. Keeping the shared
/// control-center variant under a narrow namespace makes the intended call
/// site explicit and avoids leaking overlay implementation names into pages.
enum SharedProductComponents {
    typealias SessionBubbleRow = ControlCenterSessionBubbleRow
}

struct ControlCenterSessionBubbleRow: View {
    let identity: ProductComponentIdentity
    let agentTitle: String
    let sessionTitle: String
    let lifecycle: ProductLifecycleState
    let statusTitle: String
    let message: String?
    let navigationAction: ProductActionPresentation<NavigationCapability>?
    let onNavigationAction: (NavigationCapability) -> Void

    init(
        identity: ProductComponentIdentity,
        agentTitle: String,
        sessionTitle: String,
        lifecycle: ProductLifecycleState,
        statusTitle: String,
        message: String? = nil,
        navigationAction: ProductActionPresentation<NavigationCapability>? = nil,
        onNavigationAction: @escaping (NavigationCapability) -> Void
    ) {
        self.identity = identity
        self.agentTitle = agentTitle
        self.sessionTitle = sessionTitle
        self.lifecycle = lifecycle
        self.statusTitle = statusTitle
        self.message = message
        self.navigationAction = navigationAction
        self.onNavigationAction = onNavigationAction
    }

    var body: some View {
        ProductCardSurface(padding: SharedProductComponentLayout.compactPadding) {
            VStack(alignment: .leading, spacing: SharedProductComponentLayout.rowSpacing) {
                Text(agentTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        sessionHeading
                        Spacer(minLength: 8)
                        navigationButton
                    }

                    VStack(alignment: .leading, spacing: SharedProductComponentLayout.rowSpacing) {
                        sessionHeading
                        navigationButton
                    }
                }

                if let visibleMessage {
                    Text(visibleMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            identity.accessibilityIdentifier(for: .sessionBubbleRow)
        )
    }

    private var sessionHeading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(sessionTitle)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            ProductStatusIndicator(
                presentation: ProductStatusPresentation(
                    lifecycle: lifecycle,
                    title: statusTitle
                )
            )
        }
    }

    private var visibleMessage: String? {
        SharedProductComponentText.distinctDetail(
            message,
            comparedTo: [sessionTitle, statusTitle]
        )
    }

    @ViewBuilder
    private var navigationButton: some View {
        if let navigationAction,
           navigationAction.action != .unavailable
        {
            ProductPrimaryActionButton(
                presentation: navigationAction,
                accessibilityIdentifier: identity.accessibilityIdentifier(
                    for: .sessionBubbleRow,
                    suffix: "navigation-action"
                ),
                perform: onNavigationAction
            )
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
            .background(.regularMaterial, in: shape)
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
