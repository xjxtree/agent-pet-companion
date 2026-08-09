import AgentPetCompanionCore
import SwiftUI

enum SidebarConfigurationPreviewEmptyReason: Equatable {
    case bubbleHidden
    case noSources
    case noEvents

    var systemImage: String {
        switch self {
        case .bubbleHidden: "message.slash"
        case .noSources: "antenna.radiowaves.left.and.right.slash"
        case .noEvents: "bell.slash"
        }
    }

    func title(
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        switch self {
        case .bubbleHidden:
            "\(APCLocalization.text(.configStatusBubble, locale: localeIdentifier)) · "
                + APCLocalization.text(.controlDisabled, locale: localeIdentifier)
        case .noSources:
            APCLocalization.text(.configNoSources, locale: localeIdentifier)
        case .noEvents:
            APCLocalization.text(.configNoEvents, locale: localeIdentifier)
        }
    }
}

struct SidebarConfigurationPreviewPresentation: Equatable {
    let contents: [OverlayBubbleContent]
    let emptyReason: SidebarConfigurationPreviewEmptyReason?
    let petAction: PetAnimationAction

    static let eventPriority: [AgentEventKind] = [
        .waiting,
        .failed,
        .tool,
        .thinking,
        .done,
        .plan,
        .start,
    ]

    init(
        behavior: BehaviorSettings,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) {
        // Desktop visibility controls only the real overlay. This persistent
        // sidebar preview stays available so users can evaluate the current
        // pet and bubble configuration before showing the desktop pet again.
        guard behavior.statusBubble else {
            contents = []
            emptyReason = .bubbleHidden
            petAction = .idle
            return
        }

        let sources = BehaviorSettingsCatalog.sources.filter {
            behavior.sources[$0, default: true]
        }
        guard !sources.isEmpty else {
            contents = []
            emptyReason = .noSources
            petAction = .idle
            return
        }

        let events = Self.eventPriority.filter {
            behavior.events[$0, default: true]
        }
        guard !events.isEmpty else {
            contents = []
            emptyReason = .noEvents
            petAction = .idle
            return
        }

        let previewSessions = (0 ..< 2).map { index in
            let source = behavior.groupSessionsByAgent
                ? sources[0]
                : sources[index % sources.count]
            let event = events[index % events.count]
            return Self.session(
                source: source,
                event: event,
                index: index,
                localeIdentifier: localeIdentifier
            )
        }

        if behavior.groupSessionsByAgent {
            let source = sources[0]
            contents = [OverlayBubbleContent(
                id: "sidebar-preview-agent-\(source.rawValue)",
                source: source,
                agentName: source.title,
                sessions: previewSessions,
                isExpanded: behavior.sessionGroupDisplay == .expanded
            )]
        } else if behavior.sessionGroupDisplay == .stacked {
            let session = previewSessions[0]
            contents = [OverlayBubbleContent(
                id: "sidebar-preview-session-stack",
                source: session.source,
                agentName: session.source?.title
                    ?? APCLocalization.text(.appName, locale: localeIdentifier),
                sessions: [session],
                isExpanded: false,
                isStandaloneSessionCard: true,
                standaloneStackSessionCount: previewSessions.count
            )]
        } else {
            contents = previewSessions.map { session in
                OverlayBubbleContent(
                    id: "sidebar-preview-card-\(session.id)",
                    source: session.source,
                    agentName: session.source?.title
                        ?? APCLocalization.text(.appName, locale: localeIdentifier),
                    sessions: [session],
                    isExpanded: true,
                    isStandaloneSessionCard: true,
                    standaloneStackSessionCount: 1
                )
            }
        }

        emptyReason = nil
        petAction = PetAnimationAction(rawValue: events[0].petState) ?? .idle
    }

    private static func session(
        source: AgentSource,
        event: AgentEventKind,
        index: Int,
        localeIdentifier: String
    ) -> OverlaySessionContent {
        let alias = index == 0 ? "A" : "B"
        return OverlaySessionContent(
            id: "sidebar-preview-\(source.rawValue)-\(index)",
            source: source,
            sessionID: "preview-\(index)",
            eventType: event,
            sessionTitle: APCLocalization.format(
                .overlaySessionAliasTitleFormat,
                locale: localeIdentifier,
                source.shortTitle,
                alias
            ),
            messageText: eventDetail(event, localeIdentifier: localeIdentifier),
            statusText: APCLocalizedPresentation.overlayEventTitle(
                OverlaySessionContent.summaryKind(for: event),
                locale: localeIdentifier
            )
        )
    }

    private static func eventDetail(
        _ event: AgentEventKind,
        localeIdentifier: String
    ) -> String {
        let key: APCLocalizationKey = switch event {
        case .start: .configEventStartDetail
        case .thinking: .configEventThinkingDetail
        case .plan: .configEventPlanDetail
        case .tool: .configEventToolDetail
        case .waiting: .configEventWaitingDetail
        case .done: .configEventDoneDetail
        case .failed: .configEventFailedDetail
        }
        return APCLocalization.text(key, locale: localeIdentifier)
    }
}

enum SidebarConfigurationPreviewLayout {
    static let minimumPetWidth: CGFloat = 78
    static let maximumPetWidth: CGFloat = 116

    static func petWidth(displayWidthPt: CGFloat) -> CGFloat {
        let lower = CGFloat(OverlayPlacement.minimumDisplayWidthPt)
        let upper = CGFloat(OverlayPlacement.maximumDisplayWidthPt)
        let clamped = min(max(displayWidthPt, lower), upper)
        let progress = (clamped - lower) / (upper - lower)
        return minimumPetWidth + progress * (maximumPetWidth - minimumPetWidth)
    }
}

struct SidebarConfigurationLivePreview: View {
    let behavior: BehaviorSettings
    let pet: PetSummary?
    let assetWarning: PetAssetWarning?
    let displayWidthPt: CGFloat

    private var presentation: SidebarConfigurationPreviewPresentation {
        SidebarConfigurationPreviewPresentation(behavior: behavior)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(APCDesign.accent)
                Text(APCLocalization.text(.configLivePreview))
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
            }

            bubblePreview

            petPreview
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity)
        .apcAppearanceTheme(behavior.appearanceTheme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.configuration-live-preview")
    }

    @ViewBuilder
    private var bubblePreview: some View {
        if let emptyReason = presentation.emptyReason {
            Label(emptyReason.title(), systemImage: emptyReason.systemImage)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .accessibilityIdentifier("sidebar.configuration-live-preview.empty")
        } else {
            SidebarConversationPreviewStack(
                contents: presentation.contents,
                fontScale: behavior.bubbleFontScale
            )
        }
    }

    @ViewBuilder
    private var petPreview: some View {
        let width = SidebarConfigurationPreviewLayout.petWidth(
            displayWidthPt: displayWidthPt
        )
        if let pet {
            PetActionFallbackImage(
                pet: pet,
                stateName: presentation.petAction.rawValue,
                assetWarning: assetWarning,
                fallbackScale: 0.42
            )
            .frame(width: width, height: width * 13 / 12)
            .accessibilityHidden(true)
        } else {
            Label(
                APCLocalization.text(.configNoPetPreview),
                systemImage: "pawprint.fill"
            )
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: width, height: width * 13 / 12)
            .accessibilityHidden(true)
        }
    }
}

private struct SidebarConversationPreviewStack: View {
    let contents: [OverlayBubbleContent]
    let fontScale: BubbleFontScale

    var body: some View {
        VStack(spacing: OverlayGeometry.bubbleStackSpacing) {
            ForEach(contents.prefix(2)) { content in
                SidebarConversationPreviewCard(content: content)
            }
        }
        .frame(maxWidth: .infinity)
        .environment(\.overlayBubbleFontScale, fontScale)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(APCLocalization.text(.configLiveMessagePreview))
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("sidebar.configuration-live-preview.messages")
    }

    private var accessibilityValue: String {
        contents
            .flatMap(\.visibleSessions)
            .map(\.accessibilityLabel)
            .joined(separator: "; ")
    }
}

private struct SidebarConversationPreviewCard: View {
    @Environment(\.overlayBubbleFontScale) private var fontScale
    let content: OverlayBubbleContent

    var body: some View {
        surface
            .fixedSize(horizontal: false, vertical: true)
            .background {
                if content.showsStackDecoration {
                    ForEach(
                        Array((1 ... content.stackDecorationLayerCount).reversed()),
                        id: \.self
                    ) { layer in
                        SidebarPreviewBubbleSurface(
                            semanticTintOpacity: 0.12,
                            statusTone: content.statusTone
                        )
                        .padding(.horizontal, CGFloat(layer) * layerInset)
                        .offset(y: CGFloat(layer) * layerOffset)
                    }
                }
            }
            .padding(.bottom, content.stackDecorationDepth)
    }

    @ViewBuilder
    private var surface: some View {
        Group {
            if content.isStandaloneSessionCard,
               let session = content.visibleSessions.first
            {
                SessionBubbleRow(
                    session: session,
                    action: {},
                    presentation: .standaloneSummary,
                    agentName: content.agentName
                )
                .focusable(false)
            } else {
                groupedSurface
            }
        }
        .padding(.horizontal, OverlayGeometry.bubbleLeadingPadding)
        .padding(.vertical, OverlayGeometry.bubbleVerticalPadding)
        .background {
            SidebarPreviewBubbleSurface(
                semanticTintOpacity: content.isStandaloneSessionCard ? 0.12 : 0,
                statusTone: content.statusTone
            )
        }
    }

    private var groupedSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: OverlayGeometry.bubbleHeaderGap) {
                AgentIconView(
                    source: content.source,
                    size: OverlayGeometry.bubbleHeaderAvatarWidth
                )

                Text(content.agentName)
                    .font(OverlayBubbleTypography.font(
                        .caption1,
                        weight: .semibold,
                        scale: fontScale
                    ))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if content.hasMultipleSessions {
                    HStack(spacing: 3) {
                        Text("\(content.sessionCount)")
                            .monospacedDigit()
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(content.isExpanded ? 180 : 0))
                    }
                    .font(OverlayBubbleTypography.font(
                        .caption2,
                        weight: .semibold,
                        scale: fontScale
                    ))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        Capsule().fill(
                            (content.statusTone.previewColor ?? .clear)
                                .opacity(0.24)
                        )
                    }
                }
            }
            .frame(height: OverlayGeometry.bubbleGroupHeaderHeight(
                fontScale: fontScale
            ))

            Color.clear
                .frame(height: OverlayGeometry.bubbleGroupHeaderSpacing)

            ForEach(
                Array(content.visibleSessions.enumerated()),
                id: \.element.id
            ) { index, session in
                SessionBubbleRow(session: session, action: {})
                    .focusable(false)

                if index < content.visibleSessions.count - 1 {
                    Divider()
                        .padding(.horizontal, OverlayGeometry.bubbleSessionHorizontalPadding)
                        .frame(height: OverlayGeometry.bubbleSessionDividerHeight)
                }
            }
        }
    }

    private var layerOffset: CGFloat {
        content.isStandaloneSessionCard
            ? OverlayGeometry.bubbleStandaloneStackLayerOffset
            : OverlayGeometry.bubbleCollapsedStackLayerOffset
    }

    private var layerInset: CGFloat {
        content.isStandaloneSessionCard
            ? OverlayGeometry.bubbleStandaloneStackLayerInset
            : OverlayGeometry.bubbleCollapsedStackLayerInset
    }
}

private struct SidebarPreviewBubbleSurface: View {
    let semanticTintOpacity: Double
    let statusTone: OverlaySessionGroupTone

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: 14,
            style: .continuous
        )
    }

    var body: some View {
        shape
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                if semanticTintOpacity > 0,
                   let color = statusTone.previewColor
                {
                    shape.fill(color.opacity(semanticTintOpacity))
                }
            }
            .overlay {
                shape
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

private extension OverlaySessionGroupTone {
    var previewColor: Color? {
        switch self {
        case .needsInput: .orange
        case .failed: .red
        case .ready: .green
        case .running: nil
        }
    }
}
