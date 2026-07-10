import AgentPetCompanionCore
import AppKit
import MetalKit
import SwiftUI

private enum OverlayStyle {
    static let surface = Color(red: 0.985, green: 0.985, blue: 0.975)
    static let text = Color(red: 0.10, green: 0.10, blue: 0.12)
    static let secondaryText = Color(red: 0.42, green: 0.42, blue: 0.44)
}

struct OverlayRootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var resizeFocused = false
    @State private var scaleStepFeedbackVisible = false
    @State private var scaleStepFeedbackTask: Task<Void, Never>?

    private var bubbleVisible: Bool {
        !store.overlayBubbleContents.isEmpty
    }

    private var currentEvent: AgentEvent? {
        store.activeOverlayEvent
    }

    var body: some View {
        GeometryReader { proxy in
            let petCenter = OverlayGeometry.localPoint(
                forScreenPoint: store.overlayPetScreenCenter,
                panelFrame: store.overlayScreenFrame,
                fallbackIn: proxy.size
            )
            let displayPetCenter = petCenter
            let menuCenter = OverlayGeometry.menuCenter(petCenter: displayPetCenter, scale: store.overlayScale)
            let controlsVisible = store.overlayPointerNearPet
                || store.overlayPetDragInProgress
                || store.overlayResizeInProgress
                || resizeFocused
            let resizeCenter = OverlayGeometry.resizeCenter(petCenter: displayPetCenter, scale: store.overlayScale)

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
                    controlsVisible: controlsVisible,
                    active: store.behavior.enabled,
                    onToggleBubble: { store.overlayBubbleDismissed.toggle() },
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

                ResizeHandle(
                    scale: store.overlayScale,
                    showScaleValue: OverlayScaleFeedbackVisibility.isVisible(
                        isFocused: resizeFocused,
                        isResizing: store.overlayResizeInProgress,
                        isStepFeedbackVisible: scaleStepFeedbackVisible
                    )
                )
                    .opacity(controlsVisible ? 1 : 0)
                    .position(resizeCenter)
                    .allowsHitTesting(false)
                    .zIndex(4)

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
                        store.resizeOverlay(from: initialScale, screenTranslation: screenTranslation, commit: false)
                    },
                    onResizeEnded: { initialScale, screenTranslation in
                        store.resizeOverlay(from: initialScale, screenTranslation: screenTranslation, commit: true)
                        store.setOverlayPointerNearPet(true)
                        store.updateOverlayLayout()
                    },
                    onScaleStep: { step in
                        store.setOverlayScale(store.overlayScale + step)
                        showScaleStepFeedback()
                    }
                )
                .frame(width: OverlayGeometry.resizeHitSize.width, height: OverlayGeometry.resizeHitSize.height)
                .position(resizeCenter)
                .zIndex(5)

                if store.behavior.clickMenu {
                    PetMenuButton(
                        collapsed: !bubbleVisible,
                        onToggleBubble: { store.overlayBubbleDismissed.toggle() }
                    )
                        .position(menuCenter)
                }
            }
            .onChange(of: currentEvent?.id) { _, _ in
                store.overlayBubbleDismissed = false
                store.updateOverlayLayout()
            }
            .onChange(of: store.overlayBubbleDismissed) { _, _ in
                store.updateOverlayLayout()
            }
        }
        .background(Color.clear)
        .contextMenu {
            if store.behavior.clickMenu {
                Button(bubbleVisible ? "收起气泡" : "展开气泡") {
                    store.overlayBubbleDismissed.toggle()
                }
                Button("打开主窗口") {
                    store.presentMainWindow()
                }
                Divider()
                Button("隐藏桌宠") { store.toggleOverlay() }
            }
        }
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

    private var currentEvent: AgentEvent? {
        store.activeOverlayEvent
    }

    private var contents: [OverlayBubbleContent] {
        store.overlayBubbleContents
    }

    private var controlsVisible: Bool {
        hovered
    }

    var body: some View {
        GeometryReader { proxy in
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
                            store.dismissOverlayBubble(eventID: content.id)
                        },
                        onReply: { store.presentMainWindow() }
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.08), value: controlsVisible)
        }
        .background(Color.clear)
    }

}

private struct ConversationBubble: View {
    var content: OverlayBubbleContent
    var hovered: Bool
    var onClose: () -> Void
    var onReply: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: OverlayGeometry.bubbleCornerRadius, style: .continuous)
                .fill(OverlayStyle.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: OverlayGeometry.bubbleCornerRadius, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 4, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: OverlayGeometry.bubbleHeaderGap) {
                    AgentBadge(source: content.source)

                    Text(content.agentName)
                        .font(.system(size: OverlayGeometry.bubbleHeaderFontSize, weight: .semibold))
                        .foregroundStyle(OverlayStyle.secondaryText)
                        .lineLimit(1)
                        .layoutPriority(2)
                }

                Text(content.messageText)
                    .font(.system(size: OverlayGeometry.bubbleDetailFontSize, weight: .semibold))
                    .foregroundStyle(OverlayStyle.text.opacity(0.88))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, OverlayGeometry.bubbleLeadingPadding)
            .padding(.trailing, hovered ? OverlayGeometry.bubbleTrailingPadding : 26)
            .padding(.vertical, OverlayGeometry.bubbleVerticalPadding / 2)

            if hovered {
                BubbleIconButton(systemImage: "xmark", action: onClose)
                    .padding(4)
                    .zIndex(2)

                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 15, height: 15)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 6)
                    .padding(.trailing, 8)

                Button(action: onReply) {
                    Text("回复")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(OverlayStyle.text)
                        .frame(width: 36, height: 17)
                        .background(
                            Capsule()
                                .fill(OverlayStyle.surface)
                                .overlay(Capsule().stroke(Color.black.opacity(0.10)))
                                .shadow(color: .black.opacity(0.09), radius: 4, y: 2)
                        )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 8)
                .padding(.bottom, 6)
                .zIndex(2)
            } else {
                Button(action: onClose) {
                    Image(systemName: iconName)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(iconColor)
                        .frame(width: 15, height: 15)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 6)
                .padding(.trailing, 8)
                .help("收起气泡")
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: OverlayGeometry.bubbleCornerRadius, style: .continuous))
    }

    private var iconName: String {
        switch content.eventType {
        case .failed:
            "xmark.circle.fill"
        case .waiting:
            "clock.fill"
        case .tool, .start, .review:
            "sparkles"
        case .done, .none:
            "checkmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch content.eventType {
        case .failed:
            Color(red: 0.91, green: 0.18, blue: 0.24)
        case .waiting:
            Color(red: 0.92, green: 0.58, blue: 0.13)
        case .tool, .start, .review:
            Color(red: 0.30, green: 0.42, blue: 0.95)
        case .done, .none:
            Color(red: 0.02, green: 0.70, blue: 0.25)
        }
    }
}

private struct AgentBadge: View {
    var source: AgentSource?

    var body: some View {
        Text(label)
            .font(.system(size: 8.5, weight: .black))
            .foregroundStyle(.white)
            .frame(width: OverlayGeometry.bubbleHeaderAvatarWidth, height: OverlayGeometry.bubbleHeaderAvatarWidth)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color)
            )
            .accessibilityLabel(accessibilityLabel)
    }

    private var label: String {
        switch source {
        case .codex:
            "C"
        case .claudeCode:
            "Cl"
        case .pi:
            "π"
        case .opencode:
            "O"
        case .none:
            "A"
        }
    }

    private var color: Color {
        switch source {
        case .codex:
            Color(red: 0.18, green: 0.45, blue: 0.95)
        case .claudeCode:
            Color(red: 0.50, green: 0.28, blue: 0.92)
        case .pi:
            Color(red: 0.03, green: 0.62, blue: 0.50)
        case .opencode:
            Color(red: 0.12, green: 0.12, blue: 0.14)
        case .none:
            Color(red: 0.42, green: 0.42, blue: 0.46)
        }
    }

    private var accessibilityLabel: String {
        source?.title ?? "Agent"
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
        var clickMenuEnabled = true
        var bubbleVisible = true
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
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override var mouseDownCanMoveWindow: Bool {
            false
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
            let visibleFrame = targetScreen?.visibleFrame ?? window.screen?.visibleFrame ?? window.frame
            let clampedCenter = OverlayGeometry.clampedPetScreenCenter(
                proposedCenter,
                scale: scale,
                visibleFrame: visibleFrame,
                clickMenuEnabled: clickMenuEnabled
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
            let shouldShowMenu = clickMenuEnabled && !didDrag
            dragStartMouseLocation = nil
            dragStartPetCenter = nil
            if didDrag {
                onDragEnded(finalCenter, visibleFrame)
            }
            onDragActiveChanged(false)
            if shouldShowMenu {
                showClickMenu(at: event.locationInWindow)
            }
        }

        private func screen(containing point: NSPoint) -> NSScreen? {
            NSScreen.screens.first { $0.frame.contains(point) }
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
            menu.addItem(bubbleItem)

            let openItem = NSMenuItem(
                title: "打开主窗口",
                action: #selector(PetClickMenuTarget.openMainWindow),
                keyEquivalent: ""
            )
            openItem.target = target
            menu.addItem(openItem)

            menu.addItem(.separator())
            let hideItem = NSMenuItem(
                title: "隐藏桌宠",
                action: #selector(PetClickMenuTarget.hidePet),
                keyEquivalent: ""
            )
            hideItem.target = target
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
                .shadow(color: .black.opacity(hovered ? 0.11 : 0.07), radius: hovered ? 14 : 8, y: 8)
        }
        .frame(width: 250 * scale, height: 330 * scale)
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
        context.coordinator.configure(
            view: view,
            pet: pet,
            stateName: stateName,
            stateEntryID: stateEntryID,
            fpsProfile: fpsProfile,
            active: active
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
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(OverlayStyle.secondaryText)
                .frame(width: OverlayGeometry.menuVisualSize.width, height: OverlayGeometry.menuVisualSize.height)
                .background(
                    Circle()
                        .fill(OverlayStyle.surface.opacity(0.96))
                        .overlay(Circle().stroke(Color.black.opacity(0.06)))
                        .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
                )
        }
        .buttonStyle(.plain)
        .frame(width: OverlayGeometry.menuHitSize.width, height: OverlayGeometry.menuHitSize.height)
        .contentShape(Circle())
        .help(collapsed ? "展开气泡" : "收起气泡")
        .contextMenu {
            Button(collapsed ? "展开气泡" : "收起气泡") {
                onToggleBubble()
            }
            Button("打开主窗口") {
                store.presentMainWindow()
            }
            Divider()
            Button("隐藏桌宠") {
                store.toggleOverlay()
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
                .background(
                    Circle()
                        .fill(OverlayStyle.surface)
                        .shadow(color: .black.opacity(0.13), radius: 4, y: 2)
                )
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
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(OverlayStyle.secondaryText)
                .frame(width: OverlayGeometry.resizeVisualSize.width, height: OverlayGeometry.resizeVisualSize.height)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(OverlayStyle.surface.opacity(0.97))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.black.opacity(0.06)))
                        .shadow(color: .black.opacity(0.10), radius: 4, y: 1)
                )

            if showScaleValue {
                Text("\(Int((scale * 100).rounded()))%")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(OverlayStyle.text)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .offset(x: -24, y: -27)
                    .accessibilityHidden(true)
            }
        }
            .frame(width: OverlayGeometry.resizeHitSize.width, height: OverlayGeometry.resizeHitSize.height)
            .contentShape(Rectangle())
            .help("拖拽调整桌宠大小")
    }
}
