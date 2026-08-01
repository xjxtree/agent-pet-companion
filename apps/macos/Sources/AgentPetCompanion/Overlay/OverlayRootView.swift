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
    @EnvironmentObject private var interactionPresentation: OverlayInteractionPresentationState
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
                    onDragActiveChanged: { active, interactionID in
                        controlPresentation.setActive(.pet, active)
                        if active, let interactionID {
                            store.beginOverlayPetDrag(
                                interactionID: interactionID
                            )
                        } else {
                            store.endOverlayPetDrag(
                                interactionID: interactionID
                            )
                        }
                    },
                    onDragChanged: { center, visibleFrame, interactionID in
                        store.presentOverlayPetDrag(
                            at: center,
                            visibleFrame: visibleFrame,
                            interactionID: interactionID
                        )
                    },
                    onDragEnded: { center, visibleFrame, interactionID in
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
            petScreenCenter: store.overlayPresentedPetScreenCenter,
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

    var content: OverlayBubbleContent
    var hovered: Bool
    var keyboardNavigationActive: Bool
    var glassTransparency: Double
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
                        .fill((content.statusTone.color ?? .clear).opacity(0.12))
                        .overlay {
                            RoundedRectangle(
                                cornerRadius: OverlayGeometry.bubbleCornerRadius,
                                style: .continuous
                            )
                            .stroke(
                                (content.statusTone.color ?? .clear).opacity(0.46),
                                lineWidth: 0.7
                            )
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

    private var sessionTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .move(edge: .top).combined(with: .opacity)
    }
}
private struct SessionCountButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    .font(.caption2.weight(.bold))
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
            .font(.caption2.weight(.semibold))
            .foregroundStyle(BubbleForegroundStyle.text)
            .frame(minWidth: 28, minHeight: 17)
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

private struct PetInteractionLayer: View {
    var pet: PetSummary?
    var state: AgentEventKind?
    var stateEntryID: String
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
    var onVisualEnvelopeChanged: PetVisualEnvelopeHandler?
    var onFrameHitTestChanged: PetFrameHitTestHandler?
    var onActivate: () -> Void
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
                bubbleToggleAvailable: bubbleToggleAvailable,
                petVisualEnvelope: petVisualEnvelope,
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
                displayWidthPt: displayWidthPt,
                active: active,
                reduceMotion: reduceMotion,
                hovered: controlsVisible,
                onVisualEnvelopeChanged: onVisualEnvelopeChanged,
                onFrameHitTestChanged: onFrameHitTestChanged
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
    var bubbleToggleAvailable: Bool
    var petVisualEnvelope: OverlayPetVisualEnvelope?
    var onActivate: () -> Void
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
        view.bubbleToggleAvailable = bubbleToggleAvailable
        view.petVisualEnvelope = petVisualEnvelope
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
        view.displayWidthPt = displayWidthPt
        view.petScreenCenter = petScreenCenter
        view.appearanceTheme = appearanceTheme
        view.clickMenuEnabled = clickMenuEnabled
        view.bubbleVisible = bubbleVisible
        view.bubbleToggleAvailable = bubbleToggleAvailable
        view.petVisualEnvelope = petVisualEnvelope
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
        private struct PendingPresentation {
            let center: CGPoint
            let visibleFrame: CGRect?
            let interactionID: UUID
        }

        var displayWidthPt = OverlayGeometry.defaultDisplayWidthPt
        var petScreenCenter = CGPoint.zero
        var appearanceTheme: AppearanceTheme = .system
        var clickMenuEnabled = true {
            didSet { configureAccessibilityActions() }
        }
        var bubbleVisible = true
        var bubbleToggleAvailable = true
        var petVisualEnvelope: OverlayPetVisualEnvelope?
        var onActivate: () -> Void = {}
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

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let pointer = NSEvent.mouseLocation
            let interactionID = UUID()
            dragSession = OverlayDragSession(
                interactionID: interactionID,
                startPointerScreen: pointer,
                startAnchorScreen: petScreenCenter,
                startDisplayID: displayID(for: window.screen)
            )
            window.ignoresMouseEvents = false
            onDragActiveChanged(true, interactionID)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            updateDragPresentation(
                pointer: NSEvent.mouseLocation,
                window: window,
                flushImmediately: false
            )
        }

        override func mouseUp(with event: NSEvent) {
            guard let session = dragSession else { return }
            if let window {
                updateDragPresentation(
                    pointer: NSEvent.mouseLocation,
                    window: window,
                    flushImmediately: true
                )
            } else {
                presentationDriver.flushNow()
            }
            let finalSession = dragSession ?? session
            let interactionID = finalSession.interactionID
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
                onDragEnded(finalCenter, visibleFrame, interactionID)
            } else {
                onActivate()
            }
            onDragActiveChanged(false, interactionID)
        }

        private func updateDragPresentation(
            pointer: CGPoint,
            window: NSWindow,
            flushImmediately: Bool
        ) {
            guard var session = dragSession else { return }
            session.updatePointer(pointer)
            dragSession = session
            guard session.hasCrossedThreshold else { return }

            let proposedCenter = session.proposedAnchorScreen
            let targetScreen = resolvedScreen(
                forMouseLocation: pointer,
                proposedPetCenter: proposedCenter,
                fallbackWindow: window
            )
            let screenFrame = targetScreen?.frame
                ?? window.screen?.frame
                ?? window.frame
            let visibleFrame = targetScreen?.visibleFrame
                ?? window.screen?.visibleFrame
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
            let cadence = OverlayDisplayRefreshCadence.resolved(
                for: targetScreen ?? window.screen
            )
            presentationDriver.submit(
                PendingPresentation(
                    center: center,
                    visibleFrame: visibleFrame,
                    interactionID: session.interactionID
                ),
                targetDisplayID: cadence.displayID,
                screen: targetScreen ?? window.screen,
                fallbackCadence: cadence
            ) { [weak self] presentation in
                self?.present(presentation)
            }
            if flushImmediately {
                presentationDriver.flushNow()
            }
        }

        private func present(_ pendingPresentation: PendingPresentation) {
            petScreenCenter = pendingPresentation.center
            window?.ignoresMouseEvents = false
            onDragChanged(
                pendingPresentation.center,
                pendingPresentation.visibleFrame,
                pendingPresentation.interactionID
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

        private func resolvedScreen(
            forMouseLocation mouseLocation: NSPoint,
            proposedPetCenter: CGPoint,
            fallbackWindow window: NSWindow
        ) -> NSScreen? {
            let screens = NSScreen.screens
            let displays = screens.map { screen in
                OverlayDragDisplay(
                    id: displayID(for: screen),
                    frame: screen.frame,
                    visibleFrame: screen.visibleFrame
                )
            }
            guard let resolved = OverlayDragScreenResolver.resolve(
                pointer: mouseLocation,
                proposedPetCenter: proposedPetCenter,
                displays: displays,
                fallbackDisplayID: window.screen.map { displayID(for: $0) }
            ) else {
                return window.screen ?? NSScreen.main
            }
            return screens.first { displayID(for: $0) == resolved.id }
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
    var displayWidthPt: CGFloat
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
                displayWidthPt: displayWidthPt,
                active: active,
                reduceMotion: reduceMotion,
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
    var displayWidthPt: CGFloat
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
                active: active,
                reduceMotion: reduceMotion,
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
}

private struct PetFrameLayerView: NSViewRepresentable {
    var pet: PetSummary
    var stateName: String
    var stateEntryID: String
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
                    .fill((tone.color ?? .clear).opacity(sessionCount > 0 ? 0.28 : 0.12))
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
