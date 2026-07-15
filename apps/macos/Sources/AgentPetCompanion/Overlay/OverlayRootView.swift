import AgentPetCompanionCore
import AppKit
import MetalKit
import SwiftUI

private enum OverlayStyle {
    static let text = Color.primary
    static let secondaryText = Color.secondary
}

enum OverlayPetMenuPolicy {
    static func shouldOpen(buttonNumber: Int, isEnabled: Bool) -> Bool {
        isEnabled && buttonNumber == 1
    }
}

struct OverlayRootView: View {
    @EnvironmentObject private var store: AppStore

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
            let controlsVisible = store.overlayPointerNearPet
                || store.overlayPetDragInProgress
                || store.overlayResizeInProgress

            ZStack {
                Color.clear

                PetInteractionLayer(
                    pet: store.activePet,
                    state: currentEvent?.eventType,
                    stateEntryID: currentEvent?.id ?? "idle",
                    scale: store.overlayScale,
                    fpsProfile: store.behavior.fpsProfile,
                    clickMenuEnabled: store.behavior.clickMenu,
                    bubbleVisible: bubbleVisible,
                    petScreenCenter: store.overlayPetScreenCenter,
                    petVisualEnvelope: store.overlayPetVisualEnvelope,
                    controlsVisible: controlsVisible,
                    active: store.behavior.enabled,
                    onToggleBubble: { store.toggleOverlayBubble() },
                    onOpenMainWindow: { store.presentMainWindow() },
                    onHidePet: { store.toggleOverlay() },
                    onHoverChanged: { store.setOverlayPointerNearPet($0) },
                    onDragActiveChanged: { active in
                        store.setOverlayPetDragInProgress(active)
                    },
                    onDragChanged: { center, visibleFrame in
                        guard !store.overlayResizeInProgress else { return }
                        store.moveOverlayPet(to: center, visibleFrame: visibleFrame, commit: false)
                    },
                    onDragEnded: { center, visibleFrame in
                        guard !store.overlayResizeInProgress else { return }
                        store.moveOverlayPet(to: center, visibleFrame: visibleFrame, commit: true)
                    }
                )
                .position(displayPetCenter)
            }
            .onChange(of: currentEvent?.id) { _, _ in
                store.updateOverlayLayout()
            }
            .onChange(of: store.overlayBubbleDismissed) { _, _ in
                store.updateOverlayLayout()
            }
        }
        .background(Color.clear)
    }
}

struct OverlayMenuControlRootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        PetMenuButton(
            collapsed: store.overlayBubbleContents.isEmpty,
            onToggleBubble: { store.toggleOverlayBubble() }
        )
        .frame(width: OverlayGeometry.menuHitSize.width, height: OverlayGeometry.menuHitSize.height)
    }
}

struct OverlayResizeControlRootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var resizeFocused = false
    @State private var scaleStepFeedbackVisible = false
    @State private var scaleStepFeedbackTask: Task<Void, Never>?

    private var controlsVisible: Bool {
        store.overlayPointerNearPet
            || store.overlayPetDragInProgress
            || store.overlayResizeInProgress
            || resizeFocused
    }

    var body: some View {
        ZStack {
            ResizeHandle(
                scale: store.overlayScale,
                showScaleValue: OverlayScaleFeedbackVisibility.isVisible(
                    isFocused: resizeFocused,
                    isResizing: store.overlayResizeInProgress,
                    isStepFeedbackVisible: scaleStepFeedbackVisible
                )
            )
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(false)

            ResizeInteractionRegion(
                scale: store.overlayScale,
                onHoverChanged: { hovering in
                    store.setOverlayPointerNearPet(hovering)
                },
                onFocusChanged: { focused in
                    resizeFocused = focused
                    if focused {
                        store.setOverlayPointerNearPet(true)
                    }
                },
                onResizeActiveChanged: { active in
                    if active {
                        store.setOverlayPointerNearPet(true)
                    }
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
                    store.setOverlayPointerNearPet(true)
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
        }
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
    @State private var hovered = false

    private var contents: [OverlayBubbleContent] {
        store.overlayBubbleContents
    }

    private var controlsVisible: Bool {
        hovered
    }

    var body: some View {
        GeometryReader { proxy in
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: OverlayGeometry.bubbleStackSpacing) {
                    bubbleLayer(in: proxy)
                }
            } else {
                bubbleLayer(in: proxy)
            }
        }
        .background(Color.clear)
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
            ForEach(contents.indices, id: \.self) { index in
                let content = contents[index]
                let rect = bubbleRects.indices.contains(index) ? bubbleRects[index] : .zero
                ConversationBubble(
                    content: content,
                    hovered: controlsVisible,
                    onClose: {
                        store.dismissOverlayBubble(eventIDs: content.eventIDs)
                    },
                    onOpenSession: { session in
                        store.presentAgentSession(
                            source: session.source,
                            sessionID: session.sessionID,
                            navigation: session.navigation
                        )
                    }
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            }
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.08), value: controlsVisible)
    }
}

private struct ConversationBubble: View {
    var content: OverlayBubbleContent
    var hovered: Bool
    var onClose: () -> Void
    var onOpenSession: (OverlaySessionContent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: OverlayGeometry.bubbleHeaderGap) {
                AgentIconView(
                    source: content.source,
                    size: OverlayGeometry.bubbleHeaderAvatarWidth
                )

                Text(content.agentName)
                    .font(.system(size: OverlayGeometry.bubbleHeaderFontSize, weight: .semibold))
                    .foregroundStyle(OverlayStyle.secondaryText)
                    .lineLimit(1)
                    .layoutPriority(2)

                Spacer(minLength: 8)

                if hovered {
                    BubbleIconButton(systemImage: "xmark", action: onClose)
                }
            }
            .frame(height: OverlayGeometry.bubbleGroupHeaderHeight)

            Color.clear
                .frame(height: OverlayGeometry.bubbleGroupHeaderSpacing)

            let rowHeights = OverlayGeometry.bubbleSessionRowHeights(
                bubbleWidth: OverlayGeometry.bubbleWidth,
                content: content
            )
            ForEach(content.sessions.indices, id: \.self) { index in
                let session = content.sessions[index]
                SessionBubbleRow(
                    session: session,
                    hovered: hovered,
                    action: { onOpenSession(session) }
                )
                .frame(height: rowHeights.indices.contains(index) ? rowHeights[index] : nil)

                if index < content.sessions.count - 1 {
                    Divider()
                        .padding(.horizontal, OverlayGeometry.bubbleSessionHorizontalPadding)
                        .frame(height: OverlayGeometry.bubbleSessionDividerHeight)
                }
            }
        }
        .padding(.horizontal, OverlayGeometry.bubbleLeadingPadding)
        .padding(.vertical, OverlayGeometry.bubbleVerticalPadding)
        .apcLiquidGlass(
            in: RoundedRectangle(
                cornerRadius: OverlayGeometry.bubbleCornerRadius,
                style: .continuous
            ),
            interactive: true
        )
        .contentShape(RoundedRectangle(cornerRadius: OverlayGeometry.bubbleCornerRadius, style: .continuous))
    }
}

private struct SessionBubbleRow: View {
    var session: OverlaySessionContent
    var hovered: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: OverlayGeometry.bubbleSessionTitleSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.sessionTitle)
                        .font(.system(
                            size: OverlayGeometry.bubbleSessionTitleFontSize,
                            weight: .semibold
                        ))
                        .foregroundStyle(OverlayStyle.text)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 8)

                    if !session.statusText.isEmpty {
                        Text(session.statusText)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .apcLiquidGlass(in: Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(statusColor.opacity(0.28), lineWidth: 0.75)
                                    .allowsHitTesting(false)
                            }
                    }
                }

                Text(session.messageText)
                    .font(.system(size: OverlayGeometry.bubbleDetailFontSize, weight: .medium))
                    .foregroundStyle(OverlayStyle.text.opacity(0.88))
                    .lineLimit(OverlayGeometry.bubbleDetailLineLimit)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, OverlayGeometry.bubbleSessionHorizontalPadding)
            .padding(.vertical, OverlayGeometry.bubbleSessionVerticalPadding)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovered ? Color.primary.opacity(0.05) : .clear)
            )
            .overlay(alignment: .bottomTrailing) {
                if hovered && session.canOpen {
                    HStack(spacing: 2) {
                        Text(session.actionLabel)
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(OverlayStyle.secondaryText)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .apcLiquidGlass(
                        in: Capsule(),
                        interactive: false
                    )
                    .padding(.trailing, OverlayGeometry.bubbleSessionHorizontalPadding)
                    .padding(.bottom, OverlayGeometry.bubbleSessionVerticalPadding)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!session.canOpen)
        .accessibilityLabel("\(session.sessionTitle)，\(session.statusText)，\(session.messageText)")
        .help(session.actionLabel)
    }

    private var statusColor: Color {
        switch session.eventType {
        case .waiting: .orange
        case .failed: .red
        case .done, .review: .green
        case .start, .tool: .blue
        case nil: .secondary
        }
    }
}

private struct PetInteractionLayer: View {
    var pet: PetSummary?
    var state: AgentEventKind?
    var stateEntryID: String
    var scale: CGFloat
    var fpsProfile: FpsProfile
    var clickMenuEnabled: Bool
    var bubbleVisible: Bool
    var petScreenCenter: CGPoint
    var petVisualEnvelope: OverlayPetVisualEnvelope?
    var controlsVisible: Bool
    var active: Bool
    var onToggleBubble: () -> Void
    var onOpenMainWindow: () -> Void
    var onHidePet: () -> Void
    var onHoverChanged: (Bool) -> Void
    var onDragActiveChanged: (Bool) -> Void
    var onDragChanged: (CGPoint, CGRect?) -> Void
    var onDragEnded: (CGPoint, CGRect?) -> Void

    var body: some View {
        ZStack {
            WindowDragRegion(
                scale: scale,
                petScreenCenter: petScreenCenter,
                clickMenuEnabled: clickMenuEnabled,
                bubbleVisible: bubbleVisible,
                petVisualEnvelope: petVisualEnvelope,
                onToggleBubble: onToggleBubble,
                onOpenMainWindow: onOpenMainWindow,
                onHidePet: onHidePet,
                onHoverChanged: onHoverChanged,
                onDragActiveChanged: onDragActiveChanged,
                onDragChanged: onDragChanged,
                onDragEnded: onDragEnded
            )
            .frame(
                width: OverlayGeometry.petDragSize(scale: scale).width,
                height: OverlayGeometry.petDragSize(scale: scale).height
            )

            PetStage(
                pet: pet,
                state: state,
                stateEntryID: stateEntryID,
                scale: scale,
                fpsProfile: fpsProfile,
                active: active,
                hovered: controlsVisible
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

private struct WindowDragRegion: NSViewRepresentable {
    var scale: CGFloat
    var petScreenCenter: CGPoint
    var clickMenuEnabled: Bool
    var bubbleVisible: Bool
    var petVisualEnvelope: OverlayPetVisualEnvelope?
    var onToggleBubble: () -> Void
    var onOpenMainWindow: () -> Void
    var onHidePet: () -> Void
    var onHoverChanged: (Bool) -> Void
    var onDragActiveChanged: (Bool) -> Void
    var onDragChanged: (CGPoint, CGRect?) -> Void
    var onDragEnded: (CGPoint, CGRect?) -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.scale = scale
        view.petScreenCenter = petScreenCenter
        view.clickMenuEnabled = clickMenuEnabled
        view.bubbleVisible = bubbleVisible
        view.petVisualEnvelope = petVisualEnvelope
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
        view.clickMenuEnabled = clickMenuEnabled
        view.bubbleVisible = bubbleVisible
        view.petVisualEnvelope = petVisualEnvelope
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
        var clickMenuEnabled = true {
            didSet { configureAccessibilityActions() }
        }
        var bubbleVisible = true
        var petVisualEnvelope: OverlayPetVisualEnvelope?
        var onToggleBubble: () -> Void = {}
        var onOpenMainWindow: () -> Void = {}
        var onHidePet: () -> Void = {}
        var onHoverChanged: (Bool) -> Void = { _ in }
        var onDragActiveChanged: (Bool) -> Void = { _ in }
        var onDragChanged: (CGPoint, CGRect?) -> Void = { _, _ in }
        var onDragEnded: (CGPoint, CGRect?) -> Void = { _, _ in }
        private var dragStartMouseLocation: NSPoint?
        private var dragStartPetCenter: CGPoint?
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

        override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
            if selector == #selector(accessibilityPerformShowMenu) {
                return clickMenuEnabled
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
            let distance = hypot(
                currentMouseLocation.x - dragStartMouseLocation.x,
                currentMouseLocation.y - dragStartMouseLocation.y
            )
            if distance > 3 {
                didDrag = true
            }
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
            let clampedCenter = OverlayGeometry.clampedPetScreenCenter(
                proposedCenter,
                scale: scale,
                visibleFrame: movementFrame,
                clickMenuEnabled: clickMenuEnabled,
                petVisualEnvelope: petVisualEnvelope
            )
            petScreenCenter = clampedCenter
            window.ignoresMouseEvents = false
            onDragChanged(clampedCenter, visibleFrame)
        }

        override func mouseUp(with event: NSEvent) {
            let finalCenter = petScreenCenter
            let visibleFrame = window.flatMap { window in
                resolvedScreen(
                    forMouseLocation: NSEvent.mouseLocation,
                    proposedPetCenter: finalCenter,
                    fallbackWindow: window
                )?.visibleFrame ?? window.screen?.visibleFrame
            }
            dragStartMouseLocation = nil
            dragStartPetCenter = nil
            if didDrag {
                onDragEnded(finalCenter, visibleFrame)
            }
            onDragActiveChanged(false)
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
            setAccessibilityRole(.group)
            setAccessibilityLabel("桌宠")
            setAccessibilityHelp("按住左键拖动，右击打开快捷菜单")
            configureAccessibilityActions()
        }

        private func configureAccessibilityActions() {
            guard clickMenuEnabled else {
                setAccessibilityCustomActions([])
                return
            }
            let showMenuAction = NSAccessibilityCustomAction(name: "打开快捷菜单") { [weak self] in
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
            let bubbleItem = NSMenuItem(
                title: bubbleVisible ? "收起气泡" : "展开气泡",
                action: #selector(PetClickMenuTarget.toggleBubble),
                keyEquivalent: ""
            )
            bubbleItem.target = target
            bubbleItem.image = NSImage(
                systemSymbolName: bubbleVisible ? "chevron.down" : "chevron.up",
                accessibilityDescription: nil
            )
            menu.addItem(bubbleItem)

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
                title: "隐藏桌宠",
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
    var hovered: Bool

    var body: some View {
        ZStack {
            FloatingPetSprite(
                pet: pet,
                state: state,
                stateEntryID: stateEntryID,
                scale: scale,
                fpsProfile: fpsProfile,
                active: active
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

    var body: some View {
        if let pet {
            PetFrameLayerView(
                pet: pet,
                stateName: state?.petState ?? "idle",
                stateEntryID: stateEntryID,
                fpsProfile: fpsProfile,
                active: active
            )
                .frame(width: 230 * scale, height: 310 * scale)
        } else {
            Color.clear
                .frame(width: 230 * scale, height: 310 * scale)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("尚未启用桌宠")
        }
    }
}

private struct PetFrameLayerView: NSViewRepresentable {
    @EnvironmentObject private var store: AppStore
    var pet: PetSummary
    var stateName: String
    var stateEntryID: String
    var fpsProfile: FpsProfile
    var active: Bool

    func makeCoordinator() -> PetMetalFrameRenderer {
        PetMetalFrameRenderer()
    }

    func makeNSView(context: Context) -> MTKView {
        context.coordinator.makeView()
    }

    func updateNSView(_ view: MTKView, context: Context) {
        let store = store
        let petID = pet.id
        let currentStateEntryID = stateEntryID
        context.coordinator.configure(
            view: view,
            pet: pet,
            stateName: stateName,
            stateEntryID: stateEntryID,
            fpsProfile: fpsProfile,
            active: active,
            onVisualEnvelopeChanged: { [weak store] envelope in
                store?.updateOverlayPetVisualEnvelope(
                    envelope,
                    petID: petID,
                    stateEntryID: currentStateEntryID
                )
            }
        )
    }
}

private struct PetMenuButton: View {
    @EnvironmentObject private var store: AppStore
    var collapsed: Bool
    var onToggleBubble: () -> Void

    var body: some View {
        Button(action: onToggleBubble) {
            Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(OverlayStyle.secondaryText)
                .frame(width: OverlayGeometry.menuVisualSize.width, height: OverlayGeometry.menuVisualSize.height)
                .apcLiquidGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .frame(width: OverlayGeometry.menuHitSize.width, height: OverlayGeometry.menuHitSize.height)
        .contentShape(Circle())
        .help(collapsed ? "展开气泡" : "收起气泡")
        .contextMenu {
            Button {
                onToggleBubble()
            } label: {
                Label(
                    collapsed ? "展开气泡" : "收起气泡",
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
                Label("隐藏桌宠", systemImage: "eye.slash")
            }
        }
    }
}

private struct BubbleIconButton: View {
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(OverlayStyle.secondaryText)
                .frame(width: 15, height: 15)
                .apcLiquidGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
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
                .apcLiquidGlass(
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous),
                    interactive: true
                )

            if showScaleValue {
                Text("\(Int((scale * 100).rounded()))%")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(OverlayStyle.text)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .apcLiquidGlass(in: Capsule())
                    .offset(x: -24, y: -27)
                    .accessibilityHidden(true)
            }
        }
            .frame(width: OverlayGeometry.resizeHitSize.width, height: OverlayGeometry.resizeHitSize.height)
            .contentShape(Rectangle())
            .help("拖拽调整桌宠大小")
    }
}
