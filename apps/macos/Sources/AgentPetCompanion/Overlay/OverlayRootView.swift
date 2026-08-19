import AgentPetCompanionCore
import AppKit
import MetalKit
import SwiftUI

private enum OverlayStyle {
    static let text = Color.primary
    static let secondaryText = Color.secondary
}

/// Keep the bubble foreground semantic, fully opaque, and free of blur or
/// shadows. Contrast comes from the adjustable native glass background rather
/// than from halos that soften glyph and control edges.
private enum BubbleForegroundStyle {
    static let text = Color.primary
    static let secondaryText = Color.primary
}

enum OverlayPetMenuPolicy {
    static func shouldOpen(buttonNumber: Int, isEnabled: Bool) -> Bool {
        isEnabled && buttonNumber == 1
    }

    static func showsBubbleToggle(hasAvailableBubbleContent: Bool) -> Bool {
        hasAvailableBubbleContent
    }
}

enum OverlayBubbleToggleContent: Equatable {
    case chevron(systemImage: String)
}

enum OverlayBubbleTogglePresentation {
    static func content(
        sessionCount: Int,
        revealsMoreContent: Bool,
        anchorDirection: OverlayBubbleAnchorDirection = .above
    ) -> OverlayBubbleToggleContent? {
        guard sessionCount > 0 else { return nil }
        let pointsUp = switch (anchorDirection, revealsMoreContent) {
        case (.above, true), (.below, false): true
        case (.above, false), (.below, true): false
        }
        return .chevron(systemImage: pointsUp ? "chevron.up" : "chevron.down")
    }
}

struct OverlayRootView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var controlPresentation: OverlayControlPresentationState
    @EnvironmentObject private var interactionPresentation: OverlayInteractionPresentationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var currentEvent: AgentEvent? {
        store.activeOverlayEvent
    }

    private var bubbleVisible: Bool {
        !store.overlayBubbleContents.isEmpty
    }

    private var isIdlePetPresentation: Bool {
        guard let currentEvent else { return true }
        return ProductLifecycleState(eventKind: currentEvent.eventType) == .idle
    }

    var body: some View {
        GeometryReader { proxy in
            let petCenter = OverlayGeometry.localPoint(
                // During a direct drag both the AppKit panel and the
                // transient presentation center move together without
                // publishing. Keep this local coordinate based on the last
                // published center/frame pair so an unrelated SwiftUI update
                // cannot move the pet inside its already-translated panel.
                forScreenPoint: store.overlayPetScreenCenter,
                panelFrame: store.overlayScreenFrame,
                fallbackIn: proxy.size
            )
            let displayPetCenter = interactionPresentation
                .resolvedPetLocalCenter(fallback: petCenter)
            let controlsVisible = controlPresentation.isVisible
            let presentedDisplayWidthPt =
                interactionPresentation.resolvedDisplayWidthPt(
                    fallback: store.overlayDisplayWidthPt
                )

            ZStack {
                Color.clear

                PetInteractionLayer(
                    pet: store.activePet,
                    state: currentEvent?.eventType,
                    stateEntryID: OverlayPetAnimationIdentity.stateEntryID(
                        for: store.presentedActiveAgentState
                    ),
                    interaction: interactionPresentation.petInteraction,
                    pressFeedbackActive: interactionPresentation.pressFeedbackActive,
                    displayWidthPt: presentedDisplayWidthPt,
                    appearanceTheme: store.behavior.appearanceTheme,
                    clickMenuEnabled: store.behavior.clickMenu,
                    bubbleVisible: bubbleVisible,
                    bubbleToggleAvailable: store.hasAvailableOverlayBubbleContent,
                    petScreenCenter: store.overlayPresentedPetScreenCenter,
                    petVisualEnvelope: store.overlayPetVisualEnvelope,
                    controlsVisible: controlsVisible,
                    active: store.behavior.enabled,
                    reduceMotion: reduceMotion,
                    onInteractionCompleted: { entryID in
                        interactionPresentation.complete(entryID: entryID)
                    },
                    onVisualEnvelopeChanged: { [weak store] envelope, petID, semanticOwnerEntryID in
                        store?.updateOverlayPetVisualEnvelope(
                            envelope,
                            petID: petID,
                            semanticOwnerEntryID: semanticOwnerEntryID
                        )
                    },
                    onFrameHitTestChanged: { [weak store] hitTest, petID, semanticOwnerEntryID in
                        store?.updateOverlayPetFrameHitTest(
                            hitTest,
                            petID: petID,
                            semanticOwnerEntryID: semanticOwnerEntryID
                        )
                    },
                    onPrimaryClick: {
                        if isIdlePetPresentation {
                            interactionPresentation.acknowledge(reduceMotion: reduceMotion)
                        }
                        store.toggleOverlayBubble()
                    },
                    onToggleBubble: { store.toggleOverlayBubble() },
                    onOpenMainWindow: { store.presentMainWindow() },
                    onHidePet: { store.toggleOverlay() },
                    onHoverChanged: { hovering in
                        controlPresentation.setHovered(.pet, hovering)
                        store.refreshOverlayPointerState()
                    },
                    onDragActiveChanged: { active, interactionID in
                        controlPresentation.setActive(.pet, active)
                        if active, let interactionID {
                            interactionPresentation.beginPressFeedback(
                                enabled: !store.hasAvailableOverlayBubbleContent,
                                reduceMotion: reduceMotion
                            )
                            interactionPresentation.beginDrag(
                                interactionID: interactionID,
                                center: store.overlayPresentedPetScreenCenter
                            )
                            store.beginOverlayPetDrag(
                                interactionID: interactionID
                            )
                        } else {
                            interactionPresentation.endDrag(
                                interactionID: interactionID
                            )
                            store.endOverlayPetDrag(
                                interactionID: interactionID
                            )
                        }
                    },
                    onDragChanged: { center, visibleFrame, interactionID in
                        interactionPresentation.updateDrag(
                            interactionID: interactionID,
                            center: center
                        )
                        store.presentOverlayPetDrag(
                            at: center,
                            visibleFrame: visibleFrame,
                            interactionID: interactionID
                        )
                    },
                    onDragEnded: { center, visibleFrame, interactionID in
                        interactionPresentation.updateDrag(
                            interactionID: interactionID,
                            center: center
                        )
                        store.commitOverlayPetDrag(
                            at: center,
                            visibleFrame: visibleFrame,
                            interactionID: interactionID
                        )
                    }
                )
                .position(displayPetCenter)
            }
        }
        .background(Color.clear)
        .apcAppearanceTheme(store.behavior.appearanceTheme)
    }

}

struct OverlayMenuControlRootView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var controlPresentation: OverlayControlPresentationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let sessionCount = store.overlayBubbleSessionCount
        let action = store.overlayBubbleDisclosureAction
        let content = action.flatMap {
            OverlayBubbleTogglePresentation.content(
                sessionCount: sessionCount,
                revealsMoreContent: $0.revealsMoreContent,
                anchorDirection: store.overlayBubbleAnchorDirection
            )
        }

        Group {
            if let action, let content {
                PetMenuButton(
                    sessionCount: sessionCount,
                    content: content,
                    tone: store.overlayBubbleStatusTone,
                    accessibilityLabel: disclosureActionLabel(
                        action,
                        sessionCount: sessionCount
                    ),
                    onPrimaryAction: { store.stepOverlayBubbleDisclosure() }
                )
            } else {
                Color.clear
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: OverlayGeometry.menuHitSize.width, height: OverlayGeometry.menuHitSize.height)
        .opacity(controlPresentation.isVisible ? 1 : 0)
        .animation(
            reduceMotion ? nil : .easeOut(duration: OverlayMotion.controlFadeDuration),
            value: controlPresentation.isVisible
        )
        .onHover { controlPresentation.setHovered(.menu, $0) }
        .onDisappear { controlPresentation.setHovered(.menu, false) }
        .apcAppearanceTheme(store.behavior.appearanceTheme)
    }

    private func disclosureActionLabel(
        _ action: OverlayBubbleDisclosureAction,
        sessionCount: Int
    ) -> String {
        switch action {
        case .expandStandaloneStack:
            APCLocalization.format(.overlayExpandSessionsFormat, sessionCount)
        case .collapseStandaloneStack:
            APCLocalization.format(.overlayCollapseSessionsFormat, sessionCount)
        case .revealBubble, .revealCollapsedStandaloneStack:
            APCLocalization.format(
                .overlayBubbleCountFormat,
                APCLocalization.text(.overlayExpandBubble),
                sessionCount
            )
        case .dismissBubble:
            APCLocalization.format(
                .overlayBubbleCountFormat,
                APCLocalization.text(.overlayCollapseBubble),
                sessionCount
            )
        }
    }
}

struct BubbleOverlayRootView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var controlPresentation: OverlayControlPresentationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var contents: [OverlayBubbleContent] {
        OverlayGeometry.visuallyOrderedBubbleContents(
            store.overlayBubbleContents,
            anchorDirection: store.overlayBubbleAnchorDirection
        )
    }

    var body: some View {
        GeometryReader { proxy in
            // Keep each bubble independent. A GlassEffectContainer manages
            // SwiftUI glassEffect descendants, which the AppKit
            // bubble surface is not, and it can obscure foreground content in
            // a transparent NSPanel.
            bubbleLayer(in: proxy)
        }
        .background(Color.clear)
        .apcAppearanceTheme(store.behavior.appearanceTheme)
        .onDisappear {
            controlPresentation.setHovered(.bubble, false)
        }
        .onChange(of: dynamicTypeSize) { _, _ in
            store.updateOverlayLayout()
        }
    }

    @ViewBuilder
    private func bubbleLayer(in proxy: GeometryProxy) -> some View {
        let alignLeft = OverlayGeometry.bubbleAlignsLeft(
            petScreenCenter: store.overlayPresentedPetScreenCenter,
            screenFrame: store.overlayScreenVisibleFrame
        )
        let fontScale = store.behavior.bubbleFontScale
        let bubbleRects = OverlayGeometry.bubbleRects(
            inPanelSize: proxy.size,
            visibleFrameSize: store.overlayScreenVisibleFrame.size,
            contents: contents,
            alignLeft: alignLeft,
            fontScale: fontScale
        )

        ZStack(alignment: .topLeading) {
            ForEach(Array(contents.enumerated()), id: \.element.id) { index, content in
                let rect = bubbleRects.indices.contains(index) ? bubbleRects[index] : .zero
                ConversationBubble(
                    content: content,
                    anchorDirection: store.overlayBubbleAnchorDirection,
                    hovered: controlPresentation.isVisible,
                    keyboardNavigationActive: controlPresentation.keyboardNavigationActive,
                    onClose: {
                        store.dismissOverlayBubble(eventIDs: content.dismissalIDs)
                    },
                    onToggleGroup: {
                        if content.isStandaloneSessionCard {
                            store.toggleOverlayStandaloneStack()
                        } else if let source = content.source {
                            store.toggleOverlayAgentGroup(source)
                        }
                    },
                    onActivateSession: { session in
                        store.activateOverlaySession(session)
                    },
                    onDismissSession: { session in
                        store.dismissOverlayBubble(eventID: session.id)
                    }
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .transition(reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
        .environment(\.overlayBubbleFontScale, fontScale)
        .animation(
            reduceMotion
                ? .easeOut(duration: OverlayMotion.reducedMotionCrossfadeDuration)
                : .snappy(duration: OverlayMotion.bubbleLayoutDuration, extraBounce: 0),
            value: contents
        )
        .onHover { controlPresentation.setHovered(.bubble, $0) }
    }
}

private struct ConversationBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.overlayBubbleFontScale) private var fontScale

    var content: OverlayBubbleContent
    var anchorDirection: OverlayBubbleAnchorDirection
    var hovered: Bool
    var keyboardNavigationActive: Bool
    var onClose: () -> Void
    var onToggleGroup: () -> Void
    var onActivateSession: (OverlaySessionContent) -> Void
    var onDismissSession: (OverlaySessionContent) -> Void

    private var accessibilityModel: OverlayBubbleAccessibilityModel {
        OverlayBubbleAccessibilityModel(content: content)
    }

    var body: some View {
        GeometryReader { proxy in
            let surfaceHeight = max(0, proxy.size.height - content.stackDecorationDepth)
            let surfaceOffset = anchorDirection == .below
                ? content.stackDecorationDepth
                : 0
            let stackDirection: CGFloat = anchorDirection == .above ? 1 : -1

            ZStack(alignment: .topLeading) {
                if content.showsStackDecoration {
                    ForEach(
                        Array((1 ... content.stackDecorationLayerCount).reversed()),
                        id: \.self
                    ) { layer in
                        let layerOffset = content.isStandaloneSessionCard
                            ? OverlayGeometry.bubbleStandaloneStackLayerOffset
                            : OverlayGeometry.bubbleCollapsedStackLayerOffset
                        let layerInset = content.isStandaloneSessionCard
                            ? OverlayGeometry.bubbleStandaloneStackLayerInset
                            : OverlayGeometry.bubbleCollapsedStackLayerInset
                        let inset = CGFloat(layer) * layerInset
                        let offset = CGFloat(layer) * layerOffset

                        stackDecorationLayer
                        .frame(
                            width: max(0, proxy.size.width - inset * 2),
                            height: surfaceHeight
                        )
                        .offset(
                            x: inset,
                            y: surfaceOffset + stackDirection * offset
                        )
                        .transition(.opacity)
                        .allowsHitTesting(false)
                    }
                }

                bubbleSurface
                    .frame(width: proxy.size.width, height: surfaceHeight, alignment: .top)
                    .offset(y: surfaceOffset)
            }
        }
        .accessibilityIdentifier("overlay.group.\(content.id)")
    }

    private var stackDecorationLayer: some View {
        // Every represented session remains a complete native lens in the
        // folded tray. Offsets expose the rear-card depth; no material plate,
        // gray veil, opacity reduction, or synthetic outline replaces the
        // live desktop refraction.
        Color.clear
            .modifier(ConversationBubbleSurfaceStyle(
                semanticTintOpacity: 0.12,
                statusTone: content.statusTone
            ))
    }

    private var bubbleSurface: some View {
        Group {
            if content.isStandaloneSessionCard, let session = content.sessions.first {
                standaloneSessionSurface(session)
            } else {
                groupedSessionSurface
            }
        }
        .padding(.horizontal, OverlayGeometry.bubbleLeadingPadding)
        .padding(.vertical, OverlayGeometry.bubbleVerticalPadding)
        .modifier(ConversationBubbleSurfaceStyle(
            semanticTintOpacity: content.isStandaloneSessionCard ? 0.12 : 0,
            statusTone: content.statusTone
        ))
        .contentShape(RoundedRectangle(
            cornerRadius: OverlayGeometry.bubbleCornerRadius,
            style: .continuous
        ))
        .modifier(ConversationBubbleAccessibilityActions(
            model: accessibilityModel,
            onClose: onClose,
            onToggleGroup: onToggleGroup
        ))
    }

    private func standaloneSessionSurface(_ session: OverlaySessionContent) -> some View {
        GeometryReader { proxy in
            let lineWidth = max(
                0,
                proxy.size.width - OverlayGeometry.bubbleSessionHorizontalPadding * 2
            )
            let visualSession = standaloneVisualSession(
                session,
                availableLineWidth: lineWidth
            )
            let accessoryWidth = OverlayGeometry.bubbleHeaderButtonSize(fontScale: fontScale)
                + OverlayGeometry.bubbleHeaderGap

            ZStack(alignment: .topTrailing) {
                SessionBubbleRow(
                    session: visualSession,
                    action: { performPrimarySessionAction(session) },
                    dismissAction: nil,
                    presentation: .standaloneSummary,
                    agentName: content.agentName,
                    reservedTrailingAccessoryWidth: accessoryWidth,
                    primaryActionLabel: primarySessionActionLabel
                )
                // Only the visual copy is shortened. VoiceOver continues to
                // receive the complete source title and retained body message.
                .accessibilityLabel(session.accessibilityLabel)

                HStack(spacing: OverlayGeometry.bubbleHeaderGap) {
                    if content.canDismiss {
                        BubbleIconButton(
                            systemImage: "xmark",
                            accessibilityLabel: accessibilityModel.closeActionLabel
                                ?? APCLocalization.text(.overlayCloseBubbleAccessibility),
                            accessibilityHint: accessibilityModel.closeActionHint
                                ?? APCLocalization.text(.overlayCloseBubbleHint),
                            action: onClose
                        )
                        .opacity(hovered || keyboardNavigationActive ? 1 : 0.001)
                        .animation(
                            reduceMotion
                                ? nil
                                : .easeOut(duration: OverlayMotion.controlFadeDuration),
                            value: hovered || keyboardNavigationActive
                        )
                        .allowsHitTesting(hovered || keyboardNavigationActive)
                        .accessibilityHidden(false)
                    }
                }
            }
        }
    }

    private func standaloneVisualSession(
        _ session: OverlaySessionContent,
        availableLineWidth: CGFloat
    ) -> OverlaySessionContent {
        var visualSession = session
        visualSession.sessionTitle = OverlayBubbleTypography.standaloneSessionTitle(
            session.sessionTitle,
            availableLineWidth: availableLineWidth,
            scale: fontScale
        )
        return visualSession
    }

    private var groupedSessionSurface: some View {
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
                    .foregroundStyle(BubbleForegroundStyle.secondaryText)
                    .lineLimit(1)
                    .layoutPriority(2)

                Spacer(minLength: 8)

                if content.hasMultipleSessions {
                    SessionCountButton(
                        count: content.sessionCount,
                        expanded: content.isExpanded,
                        tone: content.statusTone,
                        action: onToggleGroup
                    )
                }

                if content.canDismiss {
                    BubbleIconButton(
                        systemImage: "xmark",
                        accessibilityLabel: accessibilityModel.closeActionLabel
                            ?? APCLocalization.text(.overlayCloseBubbleAccessibility),
                        accessibilityHint: accessibilityModel.closeActionHint
                            ?? APCLocalization.text(.overlayCloseBubbleHint),
                        action: onClose
                    )
                    // Keep the control in the AX tree while preserving the
                    // hover-only visual treatment for pointer users.
                    .opacity(hovered || keyboardNavigationActive ? 1 : 0.001)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: OverlayMotion.controlFadeDuration),
                        value: hovered || keyboardNavigationActive
                    )
                    .allowsHitTesting(hovered || keyboardNavigationActive)
                    .accessibilityHidden(false)
                }
            }
            .frame(height: OverlayGeometry.bubbleGroupHeaderHeight(fontScale: fontScale))
            .accessibilityElement(children: .contain)
            .accessibilitySortPriority(100)

            Color.clear
                .frame(height: OverlayGeometry.bubbleGroupHeaderSpacing)

            let rowHeights = OverlayGeometry.bubbleSessionRowHeights(
                bubbleWidth: OverlayGeometry.bubbleWidth,
                content: content,
                fontScale: fontScale
            )
            ForEach(Array(content.visibleSessions.enumerated()), id: \.element.id) { index, session in
                SessionBubbleRow(
                    session: session,
                    action: { performPrimarySessionAction(session) },
                    dismissAction: content.canDismiss
                        ? { onDismissSession(session) }
                        : nil,
                    primaryActionLabel: primarySessionActionLabel
                )
                .frame(height: rowHeights.indices.contains(index) ? rowHeights[index] : nil)
                .accessibilitySortPriority(
                    Double(content.visibleSessions.count - index) + 10
                )
                .transition(sessionTransition)

                if index < content.visibleSessions.count - 1 {
                    Divider()
                        .padding(.horizontal, OverlayGeometry.bubbleSessionHorizontalPadding)
                        .frame(height: OverlayGeometry.bubbleSessionDividerHeight)
                        .transition(.opacity)
                }
            }
        }
    }

    private var sessionTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .move(edge: .top).combined(with: .opacity)
    }

    private var primarySessionActionLabel: String? {
        guard content.isStacked else { return nil }
        return APCLocalization.format(
            .overlayExpandSessionsFormat,
            content.disclosureSessionCount
        )
    }

    private func performPrimarySessionAction(_ session: OverlaySessionContent) {
        switch OverlayBubbleSessionPrimaryAction.resolve(content: content) {
        case .expandSessions:
            onToggleGroup()
        case .activateSession:
            onActivateSession(session)
        }
    }
}

struct ConversationBubbleSurfaceStyle: ViewModifier {
    let semanticTintOpacity: Double
    let statusTone: OverlaySessionGroupTone

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: OverlayGeometry.bubbleCornerRadius,
            style: .continuous
        )
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        content
            .background {
                if semanticTintOpacity > 0, let color = statusTone.color {
                    // Preserve the semantic terminal-state cue as a restrained
                    // foreground wash. The native lens remains full strength
                    // underneath, so the desktop still refracts through it.
                    shape.fill(color.opacity(semanticTintOpacity))
                }
            }
            .apcNativeBubbleGlass(
                cornerRadius: OverlayGeometry.bubbleCornerRadius
            )
    }
}

private struct SessionCountButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.overlayBubbleFontScale) private var fontScale

    var count: Int
    var expanded: Bool
    var tone: OverlaySessionGroupTone
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("\(count)")
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(OverlayBubbleTypography.font(
                        .caption2,
                        weight: .bold,
                        scale: fontScale
                    ))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .animation(
                        reduceMotion
                            ? nil
                            : .snappy(
                                duration: OverlayMotion.bubbleLayoutDuration,
                                extraBounce: 0
                            ),
                        value: expanded
                    )
            }
            .font(OverlayBubbleTypography.font(
                .caption2,
                weight: .semibold,
                scale: fontScale
            ))
            .foregroundStyle(BubbleForegroundStyle.text)
            .frame(
                minWidth: OverlayBubbleTypography.scaledControlMetric(28, scale: fontScale),
                minHeight: OverlayBubbleTypography.scaledControlMetric(17, scale: fontScale)
            )
            .padding(.horizontal, 5)
            .background(
                Capsule()
                    .fill((tone.color ?? .clear).opacity(0.34))
            )
            .overlay {
                Capsule()
                    .stroke((tone.color ?? .clear).opacity(0.65), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
        .frame(width: OverlayGeometry.bubbleGroupToggleWidth(fontScale: fontScale))
        .contentShape(Capsule())
        .accessibilityLabel(sessionToggleLabel)
        .help(sessionToggleLabel)
    }

    private var sessionToggleLabel: String {
        APCLocalization.format(
            expanded ? .overlayCollapseSessionsFormat : .overlayExpandSessionsFormat,
            count
        )
    }
}

private extension OverlaySessionGroupTone {
    var color: Color? {
        switch self {
        case .needsInput: .orange
        case .failed: .red
        case .ready: .green
        case .running: nil
        }
    }
}

private typealias PetVisualEnvelopeHandler = (
    OverlayPetVisualEnvelope?,
    String,
    String
) -> Void

private typealias PetFrameHitTestHandler = @MainActor (
    OverlayPetFrameHitTest?,
    String,
    String
) -> Void

private typealias PetPlaybackCompletionHandler = @MainActor (
    String,
    PetPlaybackMode
) -> Void

/// Separates the renderer's playback identity from the semantic event that
/// owns overlay geometry. A burst-then-idle handoff must restart rendering as
/// `settled-idle`, while its visible bounds and Alpha mask remain projections
/// of the original Agent event.
struct OverlayPetFrameProjectionIdentity: Equatable, Sendable {
    var semanticOwnerEntryID: String
    var renderEntryID: String

    static func resolve(
        semanticEntryID: String,
        interactionEntryID: String? = nil,
        presentsSettledIdle: Bool
    ) -> Self {
        Self(
            semanticOwnerEntryID: semanticEntryID,
            renderEntryID: interactionEntryID
                ?? (presentsSettledIdle
                    ? "\(semanticEntryID):settled-idle"
                    : semanticEntryID)
        )
    }
}

private struct PetInteractionLayer: View {
    var pet: PetSummary?
    var state: AgentEventKind?
    var stateEntryID: String
    var interaction: OverlayPetInteractionPresentation?
    var pressFeedbackActive: Bool
    var displayWidthPt: CGFloat
    var appearanceTheme: AppearanceTheme
    var clickMenuEnabled: Bool
    var bubbleVisible: Bool
    var bubbleToggleAvailable: Bool
    var petScreenCenter: CGPoint
    var petVisualEnvelope: OverlayPetVisualEnvelope?
    var controlsVisible: Bool
    var active: Bool
    var reduceMotion: Bool
    var onInteractionCompleted: @MainActor (String) -> Void
    var onVisualEnvelopeChanged: PetVisualEnvelopeHandler?
    var onFrameHitTestChanged: PetFrameHitTestHandler?
    var onPrimaryClick: () -> Void
    var onToggleBubble: () -> Void
    var onOpenMainWindow: () -> Void
    var onHidePet: () -> Void
    var onHoverChanged: (Bool) -> Void
    var onDragActiveChanged: (Bool, UUID?) -> Void
    var onDragChanged: (CGPoint, CGRect?, UUID) -> Void
    var onDragEnded: (CGPoint, CGRect?, UUID) -> Void

    var body: some View {
        ZStack {
            WindowDragRegion(
                displayWidthPt: displayWidthPt,
                petScreenCenter: petScreenCenter,
                appearanceTheme: appearanceTheme,
                clickMenuEnabled: clickMenuEnabled,
                bubbleVisible: bubbleVisible,
                menuVisible: controlsVisible,
                bubbleToggleAvailable: bubbleToggleAvailable,
                petVisualEnvelope: petVisualEnvelope,
                onPrimaryClick: onPrimaryClick,
                onToggleBubble: onToggleBubble,
                onOpenMainWindow: onOpenMainWindow,
                onHidePet: onHidePet,
                onHoverChanged: onHoverChanged,
                onDragActiveChanged: onDragActiveChanged,
                onDragChanged: onDragChanged,
                onDragEnded: onDragEnded
            )
            .frame(
                width: OverlayGeometry.petVisibleSize(
                    displayWidthPt: displayWidthPt
                ).width,
                height: OverlayGeometry.petVisibleSize(
                    displayWidthPt: displayWidthPt
                ).height
            )

            PetStage(
                pet: pet,
                state: state,
                stateEntryID: stateEntryID,
                interaction: interaction,
                displayWidthPt: displayWidthPt,
                active: active,
                reduceMotion: reduceMotion,
                hovered: controlsVisible,
                onInteractionCompleted: onInteractionCompleted,
                onVisualEnvelopeChanged: onVisualEnvelopeChanged,
                onFrameHitTestChanged: onFrameHitTestChanged
            )
            .scaleEffect(pressFeedbackActive ? 0.97 : 1)
            .animation(
                .easeOut(duration: OverlayPetInteractionPolicy.pressFeedbackDurationSeconds),
                value: pressFeedbackActive
            )
            .allowsHitTesting(false)
        }
        .frame(
            width: max(
                OverlayGeometry.petVisibleSize(
                    displayWidthPt: displayWidthPt
                ).width,
                OverlayGeometry.petDragSize(
                    displayWidthPt: displayWidthPt
                ).width
            ),
            height: max(
                OverlayGeometry.petVisibleSize(
                    displayWidthPt: displayWidthPt
                ).height,
                OverlayGeometry.petDragSize(
                    displayWidthPt: displayWidthPt
                ).height
            )
        )
        .contentShape(Rectangle())
    }

}

struct WindowDragRegion: NSViewRepresentable {
    var displayWidthPt: CGFloat
    var petScreenCenter: CGPoint
    var appearanceTheme: AppearanceTheme
    var clickMenuEnabled: Bool
    var bubbleVisible: Bool
    var menuVisible: Bool
    var bubbleToggleAvailable: Bool
    var petVisualEnvelope: OverlayPetVisualEnvelope?
    var onPrimaryClick: () -> Void
    var onToggleBubble: () -> Void
    var onOpenMainWindow: () -> Void
    var onHidePet: () -> Void
    var onHoverChanged: (Bool) -> Void
    var onDragActiveChanged: (Bool, UUID?) -> Void
    var onDragChanged: (CGPoint, CGRect?, UUID) -> Void
    var onDragEnded: (CGPoint, CGRect?, UUID) -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.displayWidthPt = displayWidthPt
        view.petScreenCenter = petScreenCenter
        view.appearanceTheme = appearanceTheme
        view.clickMenuEnabled = clickMenuEnabled
        view.bubbleVisible = bubbleVisible
        view.menuVisible = menuVisible
        view.bubbleToggleAvailable = bubbleToggleAvailable
        view.petVisualEnvelope = petVisualEnvelope
        view.onPrimaryClick = onPrimaryClick
        view.onToggleBubble = onToggleBubble
        view.onOpenMainWindow = onOpenMainWindow
        view.onHidePet = onHidePet
        view.onHoverChanged = onHoverChanged
        view.onDragActiveChanged = onDragActiveChanged
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.displayWidthPt = displayWidthPt
        view.petScreenCenter = petScreenCenter
        view.appearanceTheme = appearanceTheme
        view.clickMenuEnabled = clickMenuEnabled
        view.bubbleVisible = bubbleVisible
        view.menuVisible = menuVisible
        view.bubbleToggleAvailable = bubbleToggleAvailable
        view.petVisualEnvelope = petVisualEnvelope
        view.onPrimaryClick = onPrimaryClick
        view.onToggleBubble = onToggleBubble
        view.onOpenMainWindow = onOpenMainWindow
        view.onHidePet = onHidePet
        view.onHoverChanged = onHoverChanged
        view.onDragActiveChanged = onDragActiveChanged
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
    }

    final class DragView: NSView {
        private struct PendingPresentation {
            let center: CGPoint
            let visibleFrame: CGRect?
            let interactionID: UUID
            let boundaryClamped: Bool
            let eventTimestamp: TimeInterval
            let handlerCPUms: Double
            let refreshIntervalMS: Double
        }

        var displayWidthPt = OverlayGeometry.defaultDisplayWidthPt
        var petScreenCenter = CGPoint.zero
        var appearanceTheme: AppearanceTheme = .system
        var clickMenuEnabled = true {
            didSet { configureAccessibilityActions() }
        }
        var bubbleVisible = true
        var menuVisible = false
        var bubbleToggleAvailable = true
        var petVisualEnvelope: OverlayPetVisualEnvelope?
        var onPrimaryClick: () -> Void = {}
        var onToggleBubble: () -> Void = {}
        var onOpenMainWindow: () -> Void = {}
        var onHidePet: () -> Void = {}
        var onHoverChanged: (Bool) -> Void = { _ in }
        var onDragActiveChanged: (Bool, UUID?) -> Void = { _, _ in }
        var onDragChanged: (CGPoint, CGRect?, UUID) -> Void = { _, _, _ in }
        var onDragEnded: (CGPoint, CGRect?, UUID) -> Void = { _, _, _ in }
        private var dragSession: OverlayDragSession?
        private let presentationDriver =
            OverlayDisplayLinkCoalescer<PendingPresentation>()
        private var menuTarget: PetClickMenuTarget?
        private var displayCatalog: OverlayDragDisplayCatalog?
        private var cachedTargetScreen: (id: String, screen: NSScreen)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            configureAccessibility()
            observeScreenParameters()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            configureAccessibility()
            observeScreenParameters()
        }

        /// Target-action registration unregisters itself when the view is
        /// deallocated, so the cached desktop arrangement needs no teardown.
        private func observeScreenParameters() {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(screenParametersDidChange),
                name: NSApplication.didChangeScreenParametersNotification,
                object: nil
            )
        }

        @objc private func screenParametersDidChange() {
            displayCatalog = nil
            cachedTargetScreen = nil
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override var mouseDownCanMoveWindow: Bool {
            false
        }

        override func accessibilityPerformShowMenu() -> Bool {
            guard clickMenuEnabled else { return false }
            showClickMenu(at: NSPoint(x: bounds.midX, y: bounds.midY))
            return true
        }

        override func accessibilityPerformPress() -> Bool {
            onPrimaryClick()
            return true
        }

        override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
            if selector == NSSelectorFromString("accessibilityPerformIncrement")
                || selector == NSSelectorFromString("accessibilityPerformDecrement") {
                return false
            }
            if selector == #selector(accessibilityPerformShowMenu) {
                return clickMenuEnabled
            }
            if selector == #selector(accessibilityPerformPress) {
                return true
            }
            return super.isAccessibilitySelectorAllowed(selector)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChanged(true)
        }

        override func mouseExited(with event: NSEvent) {
            if dragSession == nil {
                onHoverChanged(false)
            }
        }

        /// Reads the pointer in absolute screen coordinates straight from the
        /// event. `locationInWindow` is expressed against the window origin the
        /// window server knew when the event was created, and this window is
        /// translated on every display tick of a drag, so converting it through
        /// the window's *current* frame subtracts a move the sample never saw.
        /// Fast drags queue several such samples per frame, and the error
        /// accumulates as the grab point sliding across the pet.
        private func pointerScreenLocation(for event: NSEvent) -> CGPoint {
            guard let location = event.cgEvent?.location,
                  let zeroOriginScreen = NSScreen.screens.first else {
                guard let window else { return event.locationInWindow }
                return window.convertPoint(toScreen: event.locationInWindow)
            }
            return OverlayPointerCoordinateSpace.screenPoint(
                forGlobalEventLocation: location,
                zeroOriginScreenFrame: zeroOriginScreen.frame
            )
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let pointer = pointerScreenLocation(for: event)
            let interactionID = UUID()
            dragSession = OverlayDragSession(
                interactionID: interactionID,
                startPointerScreen: pointer,
                startAnchorScreen: petScreenCenter,
                startDisplayID: displayID(for: window.screen)
            )
            OverlayInteractionTelemetry.shared.pointerDown(
                interactionID: interactionID,
                bubbleVisible: bubbleVisible,
                menuVisible: menuVisible
            )
            window.ignoresMouseEvents = false
            presentationDriver.beginSustainedDelivery()
            onDragActiveChanged(true, interactionID)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            updateDragPresentation(
                pointer: pointerScreenLocation(for: event),
                window: window,
                eventTimestamp: event.timestamp,
                flushImmediately: false
            )
        }

        override func mouseUp(with event: NSEvent) {
            guard let session = dragSession else { return }
            OverlayInteractionTelemetry.shared.normalMouseUp(
                interactionID: session.interactionID
            )
            if let window {
                updateDragPresentation(
                    pointer: pointerScreenLocation(for: event),
                    window: window,
                    eventTimestamp: event.timestamp,
                    flushImmediately: true
                )
            } else {
                presentationDriver.flushNow()
            }
            var finalSession = dragSession ?? session
            let interactionID = finalSession.interactionID
            guard finalSession.compareAndFinalize(
                interactionID: interactionID
            ) else { return }
            let didDrag = finalSession.hasCrossedThreshold
            let finalCenter = petScreenCenter
            let visibleFrame = window.flatMap { window in
                resolvedScreen(
                    forMouseLocation: finalSession.latestPointerScreen,
                    proposedPetCenter: finalCenter,
                    fallbackWindow: window
                )?.visibleFrame ?? window.screen?.visibleFrame
            }
            dragSession = nil
            presentationDriver.cancelPending()
            if didDrag {
                OverlayInteractionTelemetry.shared.finalFrameApplied(
                    interactionID: interactionID
                )
                onDragEnded(finalCenter, visibleFrame, interactionID)
            } else if OverlayPetPointerGesture.shouldPerformPrimaryClick(
                clickCount: event.clickCount,
                didDrag: didDrag
            ) {
                onPrimaryClick()
                OverlayInteractionTelemetry.shared.finish(
                    interactionID: interactionID,
                    result: .success
                )
            } else {
                OverlayInteractionTelemetry.shared.finish(
                    interactionID: interactionID,
                    result: .suppressed
                )
            }
            onDragActiveChanged(false, interactionID)
        }

        private func updateDragPresentation(
            pointer: CGPoint,
            window: NSWindow,
            eventTimestamp: TimeInterval,
            flushImmediately: Bool
        ) {
            let handlerStartedAt = ProcessInfo.processInfo.systemUptime
            guard var session = dragSession else { return }
            let previousPhase = session.phase
            session.updatePointer(pointer)
            dragSession = session
            guard session.hasCrossedThreshold else { return }
            if previousPhase != .dragging, session.phase == .dragging {
                OverlayInteractionTelemetry.shared.thresholdCrossed(
                    interactionID: session.interactionID
                )
            }

            let proposedCenter = session.proposedAnchorScreen
            let windowScreen = window.screen
            let targetDisplay = resolvedDisplay(
                forMouseLocation: pointer,
                proposedPetCenter: proposedCenter,
                fallbackWindow: window,
                windowScreen: windowScreen
            )
            let screenFrame = targetDisplay?.frame
                ?? windowScreen?.frame
                ?? window.frame
            let visibleFrame = targetDisplay?.visibleFrame
                ?? windowScreen?.visibleFrame
                ?? window.frame
            let movementFrame = OverlayGeometry.petMovementFrame(
                screenFrame: screenFrame,
                visibleFrame: visibleFrame
            )
            let center = OverlayPetDragGeometry.clampedCenter(
                proposedCenter,
                displayWidthPt: displayWidthPt,
                visibleFrame: movementFrame,
                clickMenuEnabled: clickMenuEnabled,
                petVisualEnvelope: petVisualEnvelope
            )
            let canonicalProposed = CGPoint(
                x: OverlayPlacementCanonicalization.cgFloatCoordinate(
                    proposedCenter.x
                ),
                y: OverlayPlacementCanonicalization.cgFloatCoordinate(
                    proposedCenter.y
                )
            )
            let catalog = displayCatalog(fallbackWindow: window)
            let cadence = targetDisplay.map { catalog.cadence(for: $0.id) }
                ?? catalog.fallbackCadence
            let targetScreen = targetDisplay
                .flatMap { screen(forDisplayID: $0.id) }
                ?? windowScreen
            let updateHandlerCPUms = (
                ProcessInfo.processInfo.systemUptime - handlerStartedAt
            ) * 1_000
            presentationDriver.submit(
                PendingPresentation(
                    center: center,
                    visibleFrame: visibleFrame,
                    interactionID: session.interactionID,
                    boundaryClamped: center != canonicalProposed,
                    eventTimestamp: eventTimestamp,
                    handlerCPUms: updateHandlerCPUms,
                    refreshIntervalMS: cadence.intervalSeconds * 1_000
                ),
                targetDisplayID: cadence.displayID,
                screen: targetScreen,
                fallbackCadence: cadence
            ) { [weak self] presentation in
                self?.present(presentation)
            }
            if flushImmediately {
                presentationDriver.flushNow()
            }
        }

        private func present(_ pendingPresentation: PendingPresentation) {
            let handlerStartedAt = ProcessInfo.processInfo.systemUptime
            guard let session = dragSession,
                  session.interactionID == pendingPresentation.interactionID,
                  session.phase == .dragging else { return }
            petScreenCenter = pendingPresentation.center
            window?.ignoresMouseEvents = false
            onDragChanged(
                pendingPresentation.center,
                pendingPresentation.visibleFrame,
                pendingPresentation.interactionID
            )
            let presentationHandlerCPUms = (
                ProcessInfo.processInfo.systemUptime - handlerStartedAt
            ) * 1_000
            OverlayInteractionTelemetry.shared.presentationApplied(
                interactionID: pendingPresentation.interactionID,
                boundaryClamped: pendingPresentation.boundaryClamped,
                eventTimestamp: pendingPresentation.eventTimestamp,
                handlerCPUms: pendingPresentation.handlerCPUms
                    + presentationHandlerCPUms,
                refreshIntervalMS: pendingPresentation.refreshIntervalMS
            )
        }

        override func rightMouseDown(with event: NSEvent) {
            guard OverlayPetMenuPolicy.shouldOpen(
                buttonNumber: event.buttonNumber,
                isEnabled: clickMenuEnabled
            ) else {
                return
            }
            showClickMenu(at: event.locationInWindow)
        }

        private func displayID(for screen: NSScreen?) -> String {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            let number = screen?.deviceDescription[key] as? NSNumber
            return number?.stringValue ?? "main"
        }

        private func configureAccessibility() {
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(APCLocalization.text(.overlayPetAccessibility))
            setAccessibilityHelp(APCLocalization.text(.overlayPetAccessibilityHelp))
            configureAccessibilityActions()
        }

        private func configureAccessibilityActions() {
            guard clickMenuEnabled else {
                setAccessibilityCustomActions([])
                return
            }
            let showMenuAction = NSAccessibilityCustomAction(
                name: APCLocalization.text(.overlayOpenQuickMenu)
            ) { [weak self] in
                self?.accessibilityPerformShowMenu() ?? false
            }
            setAccessibilityCustomActions([showMenuAction])
        }

        /// Screens are enumerated once per gesture instead of once per pointer
        /// sample. `NSScreen.screens`, each `deviceDescription` lookup, and the
        /// CoreGraphics display-mode query all run inside the event handler,
        /// and repeating them for every sample of a fast drag is main-thread
        /// work the presentation has to wait behind.
        private func displayCatalog(
            fallbackWindow window: NSWindow
        ) -> OverlayDragDisplayCatalog {
            if let displayCatalog { return displayCatalog }
            var displays: [OverlayDragDisplay] = []
            var cadences: [String: OverlayDisplayRefreshCadence] = [:]
            let screens = NSScreen.screens
            displays.reserveCapacity(screens.count)
            for screen in screens {
                let id = displayID(for: screen)
                displays.append(OverlayDragDisplay(
                    id: id,
                    frame: screen.frame,
                    visibleFrame: screen.visibleFrame
                ))
                cadences[id] = OverlayDisplayRefreshCadence.resolved(for: screen)
            }
            let catalog = OverlayDragDisplayCatalog(
                displays: displays,
                cadences: cadences,
                fallbackCadence: OverlayDisplayRefreshCadence.resolved(
                    for: window.screen ?? NSScreen.main
                )
            )
            displayCatalog = catalog
            return catalog
        }

        private func screen(forDisplayID id: String) -> NSScreen? {
            if let cachedTargetScreen, cachedTargetScreen.id == id {
                return cachedTargetScreen.screen
            }
            guard let screen = NSScreen.screens.first(where: {
                displayID(for: $0) == id
            }) else { return nil }
            cachedTargetScreen = (id, screen)
            return screen
        }

        private func resolvedDisplay(
            forMouseLocation mouseLocation: NSPoint,
            proposedPetCenter: CGPoint,
            fallbackWindow window: NSWindow,
            windowScreen: NSScreen?
        ) -> OverlayDragDisplay? {
            OverlayDragScreenResolver.resolve(
                pointer: mouseLocation,
                proposedPetCenter: proposedPetCenter,
                displays: displayCatalog(fallbackWindow: window).displays,
                fallbackDisplayID: windowScreen.map { displayID(for: $0) }
            )
        }

        private func resolvedScreen(
            forMouseLocation mouseLocation: NSPoint,
            proposedPetCenter: CGPoint,
            fallbackWindow window: NSWindow
        ) -> NSScreen? {
            guard let resolved = resolvedDisplay(
                forMouseLocation: mouseLocation,
                proposedPetCenter: proposedPetCenter,
                fallbackWindow: window,
                windowScreen: window.screen
            ) else {
                return window.screen ?? NSScreen.main
            }
            return screen(forDisplayID: resolved.id)
                ?? window.screen
                ?? NSScreen.main
        }

        private func showClickMenu(at point: NSPoint) {
            let target = PetClickMenuTarget(
                onToggleBubble: onToggleBubble,
                onOpenMainWindow: onOpenMainWindow,
                onHidePet: onHidePet
            )
            menuTarget = target

            let menu = NSMenu()
            menu.appearance = APCApplicationAppearance.nsAppearance(for: appearanceTheme)
            if OverlayPetMenuPolicy.showsBubbleToggle(
                hasAvailableBubbleContent: bubbleToggleAvailable
            ) {
                let bubbleItem = NSMenuItem(
                    title: APCLocalization.text(
                        bubbleVisible ? .overlayCollapseBubble : .overlayExpandBubble
                    ),
                    action: #selector(PetClickMenuTarget.toggleBubble),
                    keyEquivalent: ""
                )
                bubbleItem.target = target
                bubbleItem.image = NSImage(
                    systemSymbolName: bubbleVisible ? "chevron.down" : "chevron.up",
                    accessibilityDescription: nil
                )
                menu.addItem(bubbleItem)
            }

            let openItem = NSMenuItem(
                title: APCLocalization.text(.appActionOpenControlCenter),
                action: #selector(PetClickMenuTarget.openMainWindow),
                keyEquivalent: ""
            )
            openItem.target = target
            openItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
            menu.addItem(openItem)

            menu.addItem(.separator())
            let hideItem = NSMenuItem(
                title: APCLocalization.text(.appActionHidePet),
                action: #selector(PetClickMenuTarget.hidePet),
                keyEquivalent: ""
            )
            hideItem.target = target
            hideItem.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
            menu.addItem(hideItem)
            menu.popUp(positioning: nil, at: point, in: self)
        }
    }
}

private final class PetClickMenuTarget: NSObject {
    private let onToggleBubble: () -> Void
    private let onOpenMainWindow: () -> Void
    private let onHidePet: () -> Void

    init(
        onToggleBubble: @escaping () -> Void,
        onOpenMainWindow: @escaping () -> Void,
        onHidePet: @escaping () -> Void
    ) {
        self.onToggleBubble = onToggleBubble
        self.onOpenMainWindow = onOpenMainWindow
        self.onHidePet = onHidePet
    }

    @objc func toggleBubble() {
        onToggleBubble()
    }

    @objc func openMainWindow() {
        onOpenMainWindow()
    }

    @objc func hidePet() {
        onHidePet()
    }
}

private struct PetStage: View {
    var pet: PetSummary?
    var state: AgentEventKind?
    var stateEntryID: String
    var interaction: OverlayPetInteractionPresentation?
    var displayWidthPt: CGFloat
    var active: Bool
    var reduceMotion: Bool
    var hovered: Bool
    var onInteractionCompleted: @MainActor (String) -> Void
    var onVisualEnvelopeChanged: PetVisualEnvelopeHandler? = nil
    var onFrameHitTestChanged: PetFrameHitTestHandler? = nil

    var body: some View {
        ZStack {
            FloatingPetSprite(
                pet: pet,
                state: state,
                stateEntryID: stateEntryID,
                interaction: interaction,
                displayWidthPt: displayWidthPt,
                active: active,
                reduceMotion: reduceMotion,
                onInteractionCompleted: onInteractionCompleted,
                onVisualEnvelopeChanged: onVisualEnvelopeChanged,
                onFrameHitTestChanged: onFrameHitTestChanged
            )
                .shadow(color: .black.opacity(hovered ? 0.09 : 0.05), radius: hovered ? 10 : 6, y: 6)
        }
        .frame(
            width: OverlayGeometry.petVisibleSize(
                displayWidthPt: displayWidthPt
            ).width + 8,
            height: OverlayGeometry.petVisibleSize(
                displayWidthPt: displayWidthPt
            ).height + 8
        )
        .contentShape(Rectangle())
    }
}

private struct FloatingPetSprite: View {
    var pet: PetSummary?
    var state: AgentEventKind?
    var stateEntryID: String
    var interaction: OverlayPetInteractionPresentation?
    var displayWidthPt: CGFloat
    var active: Bool
    var reduceMotion: Bool
    var onInteractionCompleted: @MainActor (String) -> Void
    var onVisualEnvelopeChanged: PetVisualEnvelopeHandler? = nil
    var onFrameHitTestChanged: PetFrameHitTestHandler? = nil
    @State private var settledSemanticEntryID: String?

    private var semanticStateName: String {
        state?.petState ?? "idle"
    }

    private var semanticTiming: PetStateTiming? {
        pet?.timing(for: semanticStateName)
    }

    private var presentsSettledIdle: Bool {
        settledSemanticEntryID == stateEntryID
            && semanticTiming?.playback.mode == .burstThenIdle
    }

    private var presentedStateName: String {
        interaction?.stateName
            ?? (presentsSettledIdle ? "idle" : semanticStateName)
    }

    private var frameProjectionIdentity: OverlayPetFrameProjectionIdentity {
        .resolve(
            semanticEntryID: stateEntryID,
            interactionEntryID: interaction?.entryID,
            presentsSettledIdle: presentsSettledIdle
        )
    }

    var body: some View {
        Group {
            if let pet {
                PetFrameLayerView(
                    pet: pet,
                    stateName: presentedStateName,
                    renderEntryID: frameProjectionIdentity.renderEntryID,
                    semanticOwnerEntryID: frameProjectionIdentity.semanticOwnerEntryID,
                    active: active,
                    reduceMotion: reduceMotion,
                    onPlaybackCompleted: playbackCompleted,
                    onVisualEnvelopeChanged: onVisualEnvelopeChanged,
                    onFrameHitTestChanged: onFrameHitTestChanged
                )
                .frame(
                    width: OverlayGeometry.petVisibleSize(
                        displayWidthPt: displayWidthPt
                    ).width,
                    height: OverlayGeometry.petVisibleSize(
                        displayWidthPt: displayWidthPt
                    ).height
                )
            } else {
                Color.clear
                    .frame(
                        width: OverlayGeometry.petVisibleSize(
                            displayWidthPt: displayWidthPt
                        ).width,
                        height: OverlayGeometry.petVisibleSize(
                            displayWidthPt: displayWidthPt
                        ).height
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(APCLocalization.text(.overlayNoPet))
            }
        }
        .onChange(of: stateEntryID) { _, _ in
            settledSemanticEntryID = nil
        }
        .task(id: "\(stateEntryID):\(reduceMotion)") {
            guard reduceMotion,
                  active,
                  let semanticTiming,
                  semanticTiming.playback.mode == .burstThenIdle
            else { return }
            let repeats = max(1, semanticTiming.playback.entryRepeatCount ?? 1)
            let durationMS = semanticTiming.frameDurationsMS.reduce(0, +) * repeats
            do {
                try await Task.sleep(for: .milliseconds(durationMS))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            settledSemanticEntryID = stateEntryID
        }
    }

    @MainActor
    private func playbackCompleted(_ entryID: String, _ mode: PetPlaybackMode) {
        if mode == .onceThenReturn, interaction?.entryID == entryID {
            onInteractionCompleted(entryID)
            return
        }
        if mode == .burstThenIdle, entryID == stateEntryID {
            settledSemanticEntryID = stateEntryID
        }
    }
}

private struct PetFrameLayerView: NSViewRepresentable {
    var pet: PetSummary
    var stateName: String
    var renderEntryID: String
    var semanticOwnerEntryID: String
    var active: Bool
    var reduceMotion: Bool
    var onPlaybackCompleted: PetPlaybackCompletionHandler = { _, _ in }
    var onVisualEnvelopeChanged: PetVisualEnvelopeHandler? = nil
    var onFrameHitTestChanged: PetFrameHitTestHandler? = nil

    func makeCoordinator() -> PetMetalFrameRenderer {
        PetMetalFrameRenderer()
    }

    func makeNSView(context: Context) -> MTKView {
        context.coordinator.makeView()
    }

    func updateNSView(_ view: MTKView, context: Context) {
        let petID = pet.id
        let currentSemanticOwnerEntryID = semanticOwnerEntryID
        let onVisualEnvelopeChanged = onVisualEnvelopeChanged
        let onFrameHitTestChanged = onFrameHitTestChanged
        context.coordinator.configure(
            view: view,
            pet: pet,
            stateName: stateName,
            stateEntryID: renderEntryID,
            active: active,
            reduceMotion: reduceMotion,
            onPlaybackCompleted: onPlaybackCompleted,
            onVisualEnvelopeChanged: { envelope in
                onVisualEnvelopeChanged?(
                    envelope,
                    petID,
                    currentSemanticOwnerEntryID
                )
            },
            onFrameHitTestChanged: { hitTest in
                onFrameHitTestChanged?(
                    hitTest,
                    petID,
                    currentSemanticOwnerEntryID
                )
            }
        )
    }

    @MainActor
    static func dismantleNSView(_ view: MTKView, coordinator: PetMetalFrameRenderer) {
        // Invalidate every in-flight presentation before SwiftUI releases or
        // replaces this representable. Late drawable callbacks must never
        // reach a handler owned by a successor view with the same pet/state.
        coordinator.dismantlePipeline()
        view.isPaused = true
        view.delegate = nil
    }
}

private struct PetMenuButton: View {
    @EnvironmentObject private var store: AppStore
    var sessionCount: Int
    var content: OverlayBubbleToggleContent
    var tone: OverlaySessionGroupTone
    var accessibilityLabel: String
    var onPrimaryAction: () -> Void

    var body: some View {
        Button(action: onPrimaryAction) {
            Group {
                switch content {
                case let .chevron(systemImage):
                    Image(systemName: systemImage)
                        .font(.system(size: 9, weight: .bold))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(OverlayStyle.text)
            .frame(
                width: OverlayGeometry.menuVisualSize.width,
                height: OverlayGeometry.menuVisualSize.height
            )
            .background(
                Capsule()
                    .fill((tone.color ?? .clear).opacity(sessionCount > 0 ? 0.28 : 0.12))
            )
            .apcClearGlass(in: Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
        .frame(width: OverlayGeometry.menuHitSize.width, height: OverlayGeometry.menuHitSize.height)
        .contentShape(Capsule())
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
        .contextMenu {
            Button {
                onPrimaryAction()
            } label: {
                Label(
                    accessibilityLabel,
                    systemImage: content.systemImage
                )
            }
            Button {
                store.presentMainWindow()
            } label: {
                Label(
                    APCLocalization.text(.appActionOpenControlCenter),
                    systemImage: "macwindow"
                )
            }
            Divider()
            Button {
                store.toggleOverlay()
            } label: {
                Label(APCLocalization.text(.appActionHidePet), systemImage: "eye.slash")
            }
        }
    }

}

private extension OverlayBubbleToggleContent {
    var systemImage: String {
        switch self {
        case let .chevron(systemImage): systemImage
        }
    }
}

private struct BubbleIconButton: View {
    @Environment(\.overlayBubbleFontScale) private var fontScale

    var systemImage: String
    var accessibilityLabel: String
    var accessibilityHint: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(OverlayBubbleTypography.font(
                    .caption2,
                    weight: .bold,
                    scale: fontScale
                ))
                .foregroundStyle(BubbleForegroundStyle.secondaryText)
                .frame(
                    width: OverlayGeometry.bubbleHeaderButtonSize(fontScale: fontScale),
                    height: OverlayGeometry.bubbleHeaderButtonSize(fontScale: fontScale)
                )
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.12))
                )
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.22), lineWidth: 0.6)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .help(accessibilityHint)
    }
}

private struct ConversationBubbleAccessibilityActions: ViewModifier {
    var model: OverlayBubbleAccessibilityModel
    var onClose: () -> Void
    var onToggleGroup: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        switch (model.closeActionLabel, model.groupActionLabel) {
        case let (.some(close), .some(group)):
            content
                .accessibilityAction(named: close) { onClose() }
                .accessibilityAction(named: group) { onToggleGroup() }
        case let (.some(close), nil):
            content.accessibilityAction(named: close) { onClose() }
        case let (nil, .some(group)):
            content.accessibilityAction(named: group) { onToggleGroup() }
        case (nil, nil):
            content
        }
    }
}
