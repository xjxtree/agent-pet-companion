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
    case count(Int)
    case chevron(systemImage: String)
}

enum OverlayBubbleTogglePresentation {
    static func content(
        sessionCount: Int,
        collapsed: Bool
    ) -> OverlayBubbleToggleContent? {
        guard sessionCount > 0 else { return nil }
        if sessionCount > 1 {
            return .count(sessionCount)
        }
        return .chevron(systemImage: collapsed ? "chevron.up" : "chevron.down")
    }
}

struct OverlayRootView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var controlPresentation: OverlayControlPresentationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var currentEvent: AgentEvent? {
        store.activeOverlayEvent
    }

    private var bubbleVisible: Bool {
        !store.overlayBubbleContents.isEmpty
    }

    var body: some View {
        GeometryReader { proxy in
            let petCenter = OverlayGeometry.localPoint(
                forScreenPoint: store.overlayPetScreenCenter,
                panelFrame: store.overlayScreenFrame,
                fallbackIn: proxy.size
            )
            let displayPetCenter = petCenter
            let controlsVisible = controlPresentation.isVisible

            ZStack {
                Color.clear

                PetInteractionLayer(
                    pet: store.activePet,
                    state: currentEvent?.eventType,
                    stateEntryID: OverlayPetAnimationIdentity.stateEntryID(
                        for: store.presentedActiveAgentState
                    ),
                    scale: store.overlayScale,
                    fpsProfile: store.effectiveFPSProfile,
                    appearanceTheme: store.behavior.appearanceTheme,
                    clickMenuEnabled: store.behavior.clickMenu,
                    bubbleVisible: bubbleVisible,
                    bubbleToggleAvailable: store.hasAvailableOverlayBubbleContent,
                    petScreenCenter: store.overlayPetScreenCenter,
                    petVisualEnvelope: store.overlayPetVisualEnvelope,
                    controlsVisible: controlsVisible,
                    active: store.behavior.enabled,
                    reduceMotion: reduceMotion,
                    onVisualEnvelopeChanged: { [weak store] envelope, petID, stateEntryID in
                        store?.updateOverlayPetVisualEnvelope(
                            envelope,
                            petID: petID,
                            stateEntryID: stateEntryID
                        )
                    },
                    onFrameHitTestChanged: { [weak store] hitTest, petID, stateEntryID in
                        store?.updateOverlayPetFrameHitTest(
                            hitTest,
                            petID: petID,
                            stateEntryID: stateEntryID
                        )
                    },
                    onActivate: activatePet,
                    onToggleBubble: { store.toggleOverlayBubble() },
                    onOpenMainWindow: { store.presentMainWindow() },
                    onHidePet: { store.toggleOverlay() },
                    onHoverChanged: { hovering in
                        controlPresentation.setHovered(.pet, hovering)
                        store.refreshOverlayPointerState()
                    },
                    onDragActiveChanged: { active in
                        controlPresentation.setActive(.pet, active)
                        store.setOverlayPetDragInProgress(active)
                    },
                    onDragChanged: { center, visibleFrame in
                        guard !store.overlayResizeInProgress else { return }
                        store.presentOverlayPetDrag(
                            at: center,
                            visibleFrame: visibleFrame
                        )
                    },
                    onDragEnded: { center, velocity, visibleFrame in
                        guard !store.overlayResizeInProgress else { return }
                        store.settleOverlayPet(
                            from: center,
                            velocity: velocity,
                            visibleFrame: visibleFrame,
                            reduceMotion: reduceMotion
                        )
                    }
                )
                .position(displayPetCenter)
            }
        }
        .background(Color.clear)
        .apcAppearanceTheme(store.behavior.appearanceTheme)
    }

    private func activatePet() {
        switch OverlayPetActivationDestination.resolve(
            activeState: store.presentedActiveAgentState,
            bubbleDismissed: store.overlayBubbleDismissed,
            hasAvailableBubbleContent: store.overlayBubbleSessionCount > 0
        ) {
        case let .session(session):
            store.activateOverlaySession(session)
        case .bubble:
            store.revealOverlayBubble()
            controlPresentation.setFocused(.bubble, true)
            controlPresentation.setFocused(.bubble, false)
        case .controlCenter:
            store.presentMainWindow()
        }
    }
}

struct OverlayMenuControlRootView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var controlPresentation: OverlayControlPresentationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let sessionCount = store.overlayBubbleSessionCount
        let content = OverlayBubbleTogglePresentation.content(
            sessionCount: sessionCount,
            collapsed: store.overlayBubbleIsCollapsed
        )

        Group {
            if let content {
                PetMenuButton(
                    collapsed: store.overlayBubbleIsCollapsed,
                    sessionCount: sessionCount,
                    content: content,
                    tone: store.overlayBubbleStatusTone,
                    onToggleBubble: { store.toggleOverlayBubble() }
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
}

struct OverlayResizeControlRootView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var controlPresentation: OverlayControlPresentationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scaleStepFeedbackVisible = false
    @State private var scaleStepFeedbackTask: Task<Void, Never>?

    private var controlsVisible: Bool {
        controlPresentation.isVisible
    }

    var body: some View {
        ZStack {
            ResizeHandle(
                scale: store.overlayScale,
                showScaleValue: OverlayScaleFeedbackVisibility.isVisible(
                    isFocused: false,
                    isResizing: store.overlayResizeInProgress,
                    isStepFeedbackVisible: scaleStepFeedbackVisible
                )
            )
            .accessibilityHidden(true)
            .opacity(controlsVisible ? 1 : 0)
            .animation(
                reduceMotion ? nil : .easeOut(duration: OverlayMotion.controlFadeDuration),
                value: controlsVisible
            )
            .allowsHitTesting(false)

            ResizeInteractionRegion(
                scale: store.overlayScale,
                onHoverChanged: { hovering in
                    controlPresentation.setHovered(.resize, hovering)
                    store.refreshOverlayPointerState()
                },
                onFocusChanged: { focused in
                    controlPresentation.setFocused(.resize, focused)
                },
                onResizeActiveChanged: { active in
                    controlPresentation.setActive(.resize, active)
                    store.setOverlayResizeInProgress(active)
                },
                onResizeChanged: { initialScale, screenTranslation in
                    store.resizeOverlay(
                        from: initialScale,
                        screenTranslation: screenTranslation,
                        commit: false
                    )
                },
                onResizeEnded: { initialScale, screenTranslation in
                    store.resizeOverlay(
                        from: initialScale,
                        screenTranslation: screenTranslation,
                        commit: true
                    )
                    store.updateOverlayLayout()
                },
                onScaleStep: { step in
                    store.setOverlayScale(store.overlayScale + step)
                    showScaleStepFeedback()
                }
            )
        }
        .frame(width: OverlayGeometry.resizeHitSize.width, height: OverlayGeometry.resizeHitSize.height)
        .onDisappear {
            scaleStepFeedbackTask?.cancel()
            controlPresentation.setHovered(.resize, false)
        }
        .apcAppearanceTheme(store.behavior.appearanceTheme)
    }

    private func showScaleStepFeedback() {
        scaleStepFeedbackTask?.cancel()
        scaleStepFeedbackVisible = true
        scaleStepFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            scaleStepFeedbackVisible = false
        }
    }
}

struct BubbleOverlayRootView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var controlPresentation: OverlayControlPresentationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var contents: [OverlayBubbleContent] {
        store.overlayBubbleContents
    }

    var body: some View {
        GeometryReader { proxy in
            // Keep each bubble independent. A GlassEffectContainer elevates
            // descendant glass layers and can obscure foreground content in
            // the overlay's transparent NSPanel.
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
            petScreenCenter: store.overlayPetScreenCenter,
            screenFrame: store.overlayScreenVisibleFrame
        )
        let bubbleRects = OverlayGeometry.bubbleRects(
            inPanelSize: proxy.size,
            visibleFrameSize: store.overlayScreenVisibleFrame.size,
            contents: contents,
            alignLeft: alignLeft
        )

        ZStack(alignment: .topLeading) {
            ForEach(Array(contents.enumerated()), id: \.element.id) { index, content in
                let rect = bubbleRects.indices.contains(index) ? bubbleRects[index] : .zero
                ConversationBubble(
                    content: content,
                    hovered: controlPresentation.isVisible,
                    keyboardNavigationActive: controlPresentation.keyboardNavigationActive,
                    glassTransparency: store.behavior.bubbleTransparency,
                    onClose: {
                        store.dismissOverlayBubble(eventIDs: content.dismissalIDs)
                    },
                    onToggleGroup: {
                        guard let source = content.source else { return }
                        store.toggleOverlayAgentGroup(source)
                    },
                    onOpenControlCenter: {
                        store.selection = .connections
                        store.presentMainWindow()
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
        .animation(
            .easeInOut(duration: reduceMotion
                ? OverlayMotion.reducedMotionCrossfadeDuration
                : OverlayMotion.bubbleLayoutDuration),
            value: contents
        )
        .onHover { controlPresentation.setHovered(.bubble, $0) }
    }
}

private struct ConversationBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var content: OverlayBubbleContent
    var hovered: Bool
    var keyboardNavigationActive: Bool
    var glassTransparency: Double
    var onClose: () -> Void
    var onToggleGroup: () -> Void
    var onOpenControlCenter: () -> Void
    var onActivateSession: (OverlaySessionContent) -> Void
    var onDismissSession: (OverlaySessionContent) -> Void

    private var accessibilityModel: OverlayBubbleAccessibilityModel {
        OverlayBubbleAccessibilityModel(content: content)
    }

    var body: some View {
        GeometryReader { proxy in
            let surfaceHeight = max(0, proxy.size.height - content.stackDecorationDepth)

            ZStack(alignment: .topLeading) {
                if content.isStacked {
                    ForEach(
                        Array((1 ... OverlayGeometry.bubbleCollapsedStackLayerCount).reversed()),
                        id: \.self
                    ) { layer in
                        let inset = CGFloat(layer) * OverlayGeometry.bubbleCollapsedStackLayerInset
                        let offset = CGFloat(layer) * OverlayGeometry.bubbleCollapsedStackLayerOffset

                        RoundedRectangle(
                            cornerRadius: OverlayGeometry.bubbleCornerRadius,
                            style: .continuous
                        )
                        .fill(Color.primary.opacity(0.035))
                        .overlay {
                            RoundedRectangle(
                                cornerRadius: OverlayGeometry.bubbleCornerRadius,
                                style: .continuous
                            )
                            .stroke(.primary.opacity(0.16), lineWidth: 0.7)
                        }
                        .frame(
                            width: max(0, proxy.size.width - inset * 2),
                            height: surfaceHeight
                        )
                        .offset(x: inset, y: offset)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                    }
                }

                bubbleSurface
                    .frame(width: proxy.size.width, height: surfaceHeight, alignment: .top)
            }
            .animation(bubbleAnimation, value: content.visibleSessions.map(\.id))
            .animation(bubbleAnimation, value: content.isStacked)
        }
        .accessibilityIdentifier("overlay.group.\(content.id)")
    }

    private var bubbleSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: OverlayGeometry.bubbleHeaderGap) {
                AgentIconView(
                    source: content.source,
                    size: OverlayGeometry.bubbleHeaderAvatarWidth
                )

                Text(content.agentName)
                    .font(.caption.weight(.semibold))
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
            .frame(height: OverlayGeometry.bubbleGroupHeaderHeight)
            .accessibilityElement(children: .contain)
            .accessibilitySortPriority(100)

            Color.clear
                .frame(height: OverlayGeometry.bubbleGroupHeaderSpacing)

            let rowHeights = OverlayGeometry.bubbleSessionRowHeights(
                bubbleWidth: OverlayGeometry.bubbleWidth,
                content: content
            )
            ForEach(Array(content.visibleSessions.enumerated()), id: \.element.id) { index, session in
                SessionBubbleRow(
                    session: session,
                    action: { onActivateSession(session) },
                    dismissAction: content.canDismiss
                        ? { onDismissSession(session) }
                        : nil
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

            if content.controlCenterSessionCount > 0 {
                Divider()
                    .padding(.horizontal, OverlayGeometry.bubbleSessionHorizontalPadding)
                    .frame(height: OverlayGeometry.bubbleSessionDividerHeight)
                    .transition(.opacity)

                Button(action: onOpenControlCenter) {
                    HStack(spacing: 6) {
                        Text(APCLocalization.format(
                            .overlayMoreSessionsControlCenterFormat,
                            content.controlCenterSessionCount
                        ))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)

                        Spacer(minLength: 8)

                        Image(systemName: "arrow.up.forward.square")
                            .font(.caption.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, OverlayGeometry.bubbleSessionHorizontalPadding)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: OverlayGeometry.bubbleMoreSessionsRowHeight,
                        alignment: .leading
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("overlay.group.\(content.id).more")
                .accessibilitySortPriority(1)
                .help(APCLocalization.format(
                    .overlayMoreSessionsControlCenterFormat,
                    content.controlCenterSessionCount
                ))
                .transition(sessionTransition)
            }
        }
        .padding(.horizontal, OverlayGeometry.bubbleLeadingPadding)
        .padding(.vertical, OverlayGeometry.bubbleVerticalPadding)
        .apcTransparentBubbleGlass(
            cornerRadius: OverlayGeometry.bubbleCornerRadius,
            transparency: glassTransparency
        )
        .contentShape(RoundedRectangle(cornerRadius: OverlayGeometry.bubbleCornerRadius, style: .continuous))
        .modifier(ConversationBubbleAccessibilityActions(
            model: accessibilityModel,
            onClose: onClose,
            onToggleGroup: onToggleGroup
        ))
    }

    private var bubbleAnimation: Animation {
        .easeInOut(duration: reduceMotion
            ? OverlayMotion.reducedMotionCrossfadeDuration
            : OverlayMotion.bubbleLayoutDuration)
    }

    private var sessionTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .move(edge: .top).combined(with: .opacity)
    }
}
private struct SessionCountButton: View {
    var count: Int
    var expanded: Bool
    var tone: OverlaySessionGroupTone
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("\(count)")
                    .monospacedDigit()
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(BubbleForegroundStyle.text)
            .frame(minWidth: 28, minHeight: 17)
            .padding(.horizontal, 5)
            .background(
                Capsule()
                    .fill(tone.color.opacity(0.24))
            )
        }
        .buttonStyle(.plain)
        .frame(width: OverlayGeometry.bubbleGroupToggleWidth)
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
    var color: Color {
        switch self {
        case .needsInput: .orange
        case .failed: .red
        case .ready: .green
        case .running: .gray
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

private struct PetInteractionLayer: View {
    var pet: PetSummary?
    var state: AgentEventKind?
    var stateEntryID: String
    var scale: CGFloat
    var fpsProfile: FpsProfile
    var appearanceTheme: AppearanceTheme
    var clickMenuEnabled: Bool
    var bubbleVisible: Bool
    var bubbleToggleAvailable: Bool
    var petScreenCenter: CGPoint
    var petVisualEnvelope: OverlayPetVisualEnvelope?
    var controlsVisible: Bool
    var active: Bool
    var reduceMotion: Bool
    var onVisualEnvelopeChanged: PetVisualEnvelopeHandler?
    var onFrameHitTestChanged: PetFrameHitTestHandler?
    var onActivate: () -> Void
    var onToggleBubble: () -> Void
    var onOpenMainWindow: () -> Void
    var onHidePet: () -> Void
    var onHoverChanged: (Bool) -> Void
    var onDragActiveChanged: (Bool) -> Void
    var onDragChanged: (CGPoint, CGRect?) -> Void
    var onDragEnded: (CGPoint, CGVector, CGRect?) -> Void

    var body: some View {
        ZStack {
            WindowDragRegion(
                scale: scale,
                petScreenCenter: petScreenCenter,
                appearanceTheme: appearanceTheme,
                clickMenuEnabled: clickMenuEnabled,
                bubbleVisible: bubbleVisible,
                bubbleToggleAvailable: bubbleToggleAvailable,
                petVisualEnvelope: petVisualEnvelope,
                reduceMotion: reduceMotion,
                onActivate: onActivate,
                onToggleBubble: onToggleBubble,
                onOpenMainWindow: onOpenMainWindow,
                onHidePet: onHidePet,
                onHoverChanged: onHoverChanged,
                onDragActiveChanged: onDragActiveChanged,
                onDragChanged: onDragChanged,
                onDragEnded: onDragEnded
            )
            .frame(
                width: OverlayGeometry.petVisibleSize(scale: scale).width,
                height: OverlayGeometry.petVisibleSize(scale: scale).height
            )

            PetStage(
                pet: pet,
                state: state,
                stateEntryID: stateEntryID,
                scale: scale,
                fpsProfile: fpsProfile,
                active: active,
                reduceMotion: reduceMotion,
                hovered: controlsVisible,
                onVisualEnvelopeChanged: onVisualEnvelopeChanged,
                onFrameHitTestChanged: onFrameHitTestChanged
            )
            .allowsHitTesting(false)
        }
        .frame(
            width: max(OverlayGeometry.petVisibleSize(scale: scale).width, OverlayGeometry.petDragSize(scale: scale).width),
            height: max(OverlayGeometry.petVisibleSize(scale: scale).height, OverlayGeometry.petDragSize(scale: scale).height)
        )
        .contentShape(Rectangle())
    }
}

struct WindowDragRegion: NSViewRepresentable {
    var scale: CGFloat
    var petScreenCenter: CGPoint
    var appearanceTheme: AppearanceTheme
    var clickMenuEnabled: Bool
    var bubbleVisible: Bool
    var bubbleToggleAvailable: Bool
    var petVisualEnvelope: OverlayPetVisualEnvelope?
    var reduceMotion: Bool
    var onActivate: () -> Void
    var onToggleBubble: () -> Void
    var onOpenMainWindow: () -> Void
    var onHidePet: () -> Void
    var onHoverChanged: (Bool) -> Void
    var onDragActiveChanged: (Bool) -> Void
    var onDragChanged: (CGPoint, CGRect?) -> Void
    var onDragEnded: (CGPoint, CGVector, CGRect?) -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.scale = scale
        view.petScreenCenter = petScreenCenter
        view.appearanceTheme = appearanceTheme
        view.clickMenuEnabled = clickMenuEnabled
        view.bubbleVisible = bubbleVisible
        view.bubbleToggleAvailable = bubbleToggleAvailable
        view.petVisualEnvelope = petVisualEnvelope
        view.reduceMotion = reduceMotion
        view.onActivate = onActivate
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
        view.scale = scale
        view.petScreenCenter = petScreenCenter
        view.appearanceTheme = appearanceTheme
        view.clickMenuEnabled = clickMenuEnabled
        view.bubbleVisible = bubbleVisible
        view.bubbleToggleAvailable = bubbleToggleAvailable
        view.petVisualEnvelope = petVisualEnvelope
        view.reduceMotion = reduceMotion
        view.onActivate = onActivate
        view.onToggleBubble = onToggleBubble
        view.onOpenMainWindow = onOpenMainWindow
        view.onHidePet = onHidePet
        view.onHoverChanged = onHoverChanged
        view.onDragActiveChanged = onDragActiveChanged
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
    }

    final class DragView: NSView {
        var scale: CGFloat = 1
        var petScreenCenter = CGPoint.zero
        var appearanceTheme: AppearanceTheme = .system
        var clickMenuEnabled = true {
            didSet { configureAccessibilityActions() }
        }
        var bubbleVisible = true
        var bubbleToggleAvailable = true
        var petVisualEnvelope: OverlayPetVisualEnvelope?
        var reduceMotion = false
        var onActivate: () -> Void = {}
        var onToggleBubble: () -> Void = {}
        var onOpenMainWindow: () -> Void = {}
        var onHidePet: () -> Void = {}
        var onHoverChanged: (Bool) -> Void = { _ in }
        var onDragActiveChanged: (Bool) -> Void = { _ in }
        var onDragChanged: (CGPoint, CGRect?) -> Void = { _, _ in }
        var onDragEnded: (CGPoint, CGVector, CGRect?) -> Void = { _, _, _ in }
        private var dragStartMouseLocation: NSPoint?
        private var dragStartPetCenter: CGPoint?
        private var motionSamples: [OverlayPetMotionSample] = []
        private var didDrag = false
        private var menuTarget: PetClickMenuTarget?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            configureAccessibility()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            configureAccessibility()
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
            onActivate()
            return true
        }

        override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
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
            if dragStartMouseLocation == nil {
                onHoverChanged(false)
            }
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            dragStartMouseLocation = NSEvent.mouseLocation
            dragStartPetCenter = petScreenCenter
            motionSamples = [
                OverlayPetMotionSample(
                    point: NSEvent.mouseLocation,
                    timestamp: event.timestamp
                ),
            ]
            didDrag = false
            window.ignoresMouseEvents = false
            onDragActiveChanged(true)
        }

        override func mouseDragged(with event: NSEvent) {
            guard
                let window,
                let dragStartMouseLocation,
                let dragStartPetCenter
            else { return }

            let currentMouseLocation = NSEvent.mouseLocation
            recordMotionSample(
                point: currentMouseLocation,
                timestamp: event.timestamp
            )
            guard OverlayPetPointerGesture.exceedsDragThreshold(
                from: dragStartMouseLocation,
                to: currentMouseLocation
            ) else { return }
            didDrag = true
            let proposedCenter = CGPoint(
                x: dragStartPetCenter.x + currentMouseLocation.x - dragStartMouseLocation.x,
                y: dragStartPetCenter.y + currentMouseLocation.y - dragStartMouseLocation.y
            )
            let targetScreen = resolvedScreen(
                forMouseLocation: currentMouseLocation,
                proposedPetCenter: proposedCenter,
                fallbackWindow: window
            )
            let screenFrame = targetScreen?.frame ?? window.screen?.frame ?? window.frame
            let visibleFrame = targetScreen?.visibleFrame ?? window.screen?.visibleFrame ?? window.frame
            let movementFrame = OverlayGeometry.petMovementFrame(
                screenFrame: screenFrame,
                visibleFrame: visibleFrame
            )
            let presentationCenter = reduceMotion
                ? OverlayGeometry.clampedPetScreenCenter(
                    proposedCenter,
                    scale: scale,
                    visibleFrame: movementFrame,
                    clickMenuEnabled: clickMenuEnabled,
                    petVisualEnvelope: petVisualEnvelope
                )
                : OverlayPetDragMotion.rubberBandedCenter(
                    proposedCenter,
                    scale: scale,
                    visibleFrame: movementFrame,
                    clickMenuEnabled: clickMenuEnabled,
                    petVisualEnvelope: petVisualEnvelope
                )
            petScreenCenter = presentationCenter
            window.ignoresMouseEvents = false
            onDragChanged(presentationCenter, visibleFrame)
        }

        override func mouseUp(with event: NSEvent) {
            recordMotionSample(
                point: NSEvent.mouseLocation,
                timestamp: event.timestamp
            )
            let finalCenter = petScreenCenter
            let velocity = reduceMotion
                ? CGVector.zero
                : OverlayPetDragMotion.estimatedVelocity(from: motionSamples)
            let visibleFrame = window.flatMap { window in
                resolvedScreen(
                    forMouseLocation: NSEvent.mouseLocation,
                    proposedPetCenter: finalCenter,
                    fallbackWindow: window
                )?.visibleFrame ?? window.screen?.visibleFrame
            }
            dragStartMouseLocation = nil
            dragStartPetCenter = nil
            motionSamples.removeAll(keepingCapacity: true)
            if didDrag {
                onDragEnded(finalCenter, velocity, visibleFrame)
            } else {
                onActivate()
            }
            onDragActiveChanged(false)
        }

        private func recordMotionSample(
            point: CGPoint,
            timestamp: TimeInterval
        ) {
            motionSamples.append(OverlayPetMotionSample(
                point: point,
                timestamp: timestamp
            ))
            let cutoff = timestamp - OverlayPetDragMotion.velocityWindow
            motionSamples.removeAll { $0.timestamp < cutoff }
            if motionSamples.count > 8 {
                motionSamples.removeFirst(motionSamples.count - 8)
            }
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

        private func screen(containing point: NSPoint) -> NSScreen? {
            NSScreen.screens.first { $0.frame.contains(point) }
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

        private func resolvedScreen(
            forMouseLocation mouseLocation: NSPoint,
            proposedPetCenter: CGPoint,
            fallbackWindow window: NSWindow
        ) -> NSScreen? {
            screen(containing: mouseLocation)
                ?? screen(containing: proposedPetCenter)
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
    var scale: CGFloat
    var fpsProfile: FpsProfile
    var active: Bool
    var reduceMotion: Bool
    var hovered: Bool
    var onVisualEnvelopeChanged: PetVisualEnvelopeHandler? = nil
    var onFrameHitTestChanged: PetFrameHitTestHandler? = nil

    var body: some View {
        ZStack {
            FloatingPetSprite(
                pet: pet,
                state: state,
                stateEntryID: stateEntryID,
                scale: scale,
                fpsProfile: fpsProfile,
                active: active,
                reduceMotion: reduceMotion,
                onVisualEnvelopeChanged: onVisualEnvelopeChanged,
                onFrameHitTestChanged: onFrameHitTestChanged
            )
                .shadow(color: .black.opacity(hovered ? 0.09 : 0.05), radius: hovered ? 10 : 6, y: 6)
        }
        .frame(width: 238 * scale, height: 318 * scale)
        .contentShape(Rectangle())
    }
}

private struct FloatingPetSprite: View {
    var pet: PetSummary?
    var state: AgentEventKind?
    var stateEntryID: String
    var scale: CGFloat
    var fpsProfile: FpsProfile
    var active: Bool
    var reduceMotion: Bool
    var onVisualEnvelopeChanged: PetVisualEnvelopeHandler? = nil
    var onFrameHitTestChanged: PetFrameHitTestHandler? = nil

    var body: some View {
        if let pet {
            PetFrameLayerView(
                pet: pet,
                stateName: state?.petState ?? "idle",
                stateEntryID: stateEntryID,
                fpsProfile: fpsProfile,
                active: active,
                reduceMotion: reduceMotion,
                onVisualEnvelopeChanged: onVisualEnvelopeChanged,
                onFrameHitTestChanged: onFrameHitTestChanged
            )
                .frame(width: 230 * scale, height: 310 * scale)
        } else {
            Color.clear
                .frame(width: 230 * scale, height: 310 * scale)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(APCLocalization.text(.overlayNoPet))
        }
    }
}

private struct PetFrameLayerView: NSViewRepresentable {
    var pet: PetSummary
    var stateName: String
    var stateEntryID: String
    var fpsProfile: FpsProfile
    var active: Bool
    var reduceMotion: Bool
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
        let currentStateEntryID = stateEntryID
        let onVisualEnvelopeChanged = onVisualEnvelopeChanged
        let onFrameHitTestChanged = onFrameHitTestChanged
        context.coordinator.configure(
            view: view,
            pet: pet,
            stateName: stateName,
            stateEntryID: stateEntryID,
            fpsProfile: fpsProfile,
            active: active,
            reduceMotion: reduceMotion,
            onVisualEnvelopeChanged: { envelope in
                onVisualEnvelopeChanged?(
                    envelope,
                    petID,
                    currentStateEntryID
                )
            },
            onFrameHitTestChanged: { hitTest in
                onFrameHitTestChanged?(
                    hitTest,
                    petID,
                    currentStateEntryID
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
    var collapsed: Bool
    var sessionCount: Int
    var content: OverlayBubbleToggleContent
    var tone: OverlaySessionGroupTone
    var onToggleBubble: () -> Void

    var body: some View {
        Button(action: onToggleBubble) {
            Group {
                switch content {
                case let .count(count):
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .accessibilityHidden(true)
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
                    .fill(tone.color.opacity(sessionCount > 0 ? 0.28 : 0.12))
            )
            .apcFloatingControlGlass(in: Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
        .frame(width: OverlayGeometry.menuHitSize.width, height: OverlayGeometry.menuHitSize.height)
        .contentShape(Capsule())
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
        .contextMenu {
            Button {
                onToggleBubble()
            } label: {
                Label(
                    accessibilityLabel,
                    systemImage: collapsed ? "chevron.up" : "chevron.down"
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

    private var accessibilityLabel: String {
        let action = APCLocalization.text(
            collapsed ? .overlayExpandBubble : .overlayCollapseBubble
        )
        return sessionCount > 0
            ? APCLocalization.format(.overlayBubbleCountFormat, action, sessionCount)
            : action
    }
}

private struct BubbleIconButton: View {
    var systemImage: String
    var accessibilityLabel: String
    var accessibilityHint: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(BubbleForegroundStyle.secondaryText)
                .frame(
                    width: OverlayGeometry.bubbleHeaderButtonSize,
                    height: OverlayGeometry.bubbleHeaderButtonSize
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

private struct ResizeInteractionRegion: NSViewRepresentable {
    var scale: CGFloat
    var onHoverChanged: (Bool) -> Void
    var onFocusChanged: (Bool) -> Void
    var onResizeActiveChanged: (Bool) -> Void
    var onResizeChanged: (CGFloat, CGSize) -> Void
    var onResizeEnded: (CGFloat, CGSize) -> Void
    var onScaleStep: (CGFloat) -> Void

    func makeNSView(context: Context) -> OverlayResizeAccessibilityView {
        let view = OverlayResizeAccessibilityView()
        view.scale = scale
        view.onHoverChanged = onHoverChanged
        view.onFocusChanged = onFocusChanged
        view.onResizeActiveChanged = onResizeActiveChanged
        view.onResizeChanged = onResizeChanged
        view.onResizeEnded = onResizeEnded
        view.onScaleStep = onScaleStep
        return view
    }

    func updateNSView(_ view: OverlayResizeAccessibilityView, context: Context) {
        view.scale = scale
        view.onHoverChanged = onHoverChanged
        view.onFocusChanged = onFocusChanged
        view.onResizeActiveChanged = onResizeActiveChanged
        view.onResizeChanged = onResizeChanged
        view.onResizeEnded = onResizeEnded
        view.onScaleStep = onScaleStep
    }
}

struct ResizeHandle: View {
    var scale: CGFloat = OverlayGeometry.defaultScale
    var showScaleValue = false

    var body: some View {
        ZStack {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(OverlayStyle.secondaryText)
                .frame(width: OverlayGeometry.resizeVisualSize.width, height: OverlayGeometry.resizeVisualSize.height)
                .apcFloatingControlGlass(
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous),
                    interactive: true
                )

            if showScaleValue {
                Text(APCLocalization.format(
                    .commonPercentFormat,
                    Int((scale * 100).rounded())
                ))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(OverlayStyle.text)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .apcFloatingControlGlass(in: Capsule())
                    .offset(x: -24, y: -27)
                    .accessibilityHidden(true)
            }
        }
            .frame(width: OverlayGeometry.resizeHitSize.width, height: OverlayGeometry.resizeHitSize.height)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(APCLocalization.text(.overlayResizeHelp))
            .accessibilityValue(APCLocalization.format(
                .commonPercentFormat,
                Int((scale * 100).rounded())
            ))
            .accessibilityHint(APCLocalization.text(.overlayResizeHelp))
            .help(APCLocalization.text(.overlayResizeHelp))
    }
}
