import AgentPetCompanionCore
import AppKit
import CoreGraphics
import MetalKit
import QuartzCore
import SwiftUI

struct OverlayDesktopVisibilityPolicy {
    private(set) var controlCenterIsOpen = false

    mutating func controlCenterDidOpen() {
        controlCenterIsOpen = true
    }

    mutating func controlCenterDidClose() {
        controlCenterIsOpen = false
    }

    func shouldHide(
        rendererValidationActive: Bool,
        frontmostApplicationIsFinder: Bool,
        finderHasRegularWindow: Bool,
        hasVisibleRegularApplicationWindow: Bool
    ) -> Bool {
        // The desktop pet is a resident surface, not a child of the control
        // center. Once that window is explicitly closed, an empty layer-0
        // window list describes the expected resident-app state and must not
        // be mistaken for the system Show Desktop gesture.
        guard controlCenterIsOpen, !rendererValidationActive else {
            return false
        }
        if frontmostApplicationIsFinder {
            return !finderHasRegularWindow
        }
        return !hasVisibleRegularApplicationWindow
    }
}

enum OverlaySessionPrimaryClickPolicy {
    static func shouldActivate(_ session: OverlaySessionContent) -> Bool {
        session.canOpen
    }
}

/// Repairs the concrete AppKit child-window relationship used by the overlay
/// composition. AppKit may detach a child after it is ordered out, so callers
/// invoke this immediately before every auxiliary show operation.
@MainActor
enum OverlayAuxiliaryPanelAttachment {
    static func ensure(parent: NSWindow, auxiliary: NSWindow) {
        guard parent !== auxiliary else { return }
        let plan = OverlayAuxiliaryPanelAttachmentPolicy.plan(
            currentParentMatchesTarget: auxiliary.parent === parent,
            hasCurrentParent: auxiliary.parent != nil,
            wouldCreateCycle: parent.parent === auxiliary
        )
        switch plan {
        case .none:
            return
        case .rejectCycle:
            auxiliary.removeChildWindow(parent)
        case .reparent:
            auxiliary.parent?.removeChildWindow(auxiliary)
        case .attach:
            break
        }
        if auxiliary.parent !== parent {
            parent.addChildWindow(auxiliary, ordered: .above)
        }
    }
}

@MainActor
final class PetOverlayController {
    private var panel: NSPanel?
    private var bubblePanel: NSPanel?
    private var menuPanel: NSPanel?
    private weak var store: AppStore?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var desktopVisibilityTimer: Timer?
    private var hiddenForDesktop = false
    private var desktopVisibilityPolicy = OverlayDesktopVisibilityPolicy()
    private let controlPresentation = OverlayControlPresentationState()
    private let interactionPresentation = OverlayInteractionPresentationState()
    private var controlPanelFadeOutTask: Task<Void, Never>?
    private var bubbleAnimationGeneration: UInt = 0
    private var presentedPetScreenCenter: CGPoint?
    private var directManipulationSnapshot:
        OverlayAuxiliaryRelativeFrameSnapshot?
    private var bubbleAnchorDirection: OverlayBubbleAnchorDirection?

    func endPetDragInteraction(_ interactionID: UUID?) {
        interactionPresentation.endDrag(interactionID: interactionID)
    }

    func show(store: AppStore) {
        self.store = store
        controlPresentation.visibilityDidChange = { [weak self] in
            guard let self, let store = self.store else { return }
            self.fitControlPanels(for: store)
        }
        if panel != nil {
            updateAppearance(store.behavior.appearanceTheme)
            setVisible(store.behavior.enabled)
            return
        }

        let root = OverlayRootView()
            .environmentObject(store)
            .environmentObject(controlPresentation)
            .environmentObject(interactionPresentation)
            .apcInterfaceLanguage(store)
        let hostingView = PassthroughOverlayHostingView(rootView: root, store: store, includeBubble: false)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let bubbleRoot = BubbleOverlayRootView()
            .environmentObject(store)
            .environmentObject(controlPresentation)
            .apcInterfaceLanguage(store)
        let bubbleHostingView = PassthroughBubbleHostingView(rootView: bubbleRoot, store: store)
        bubbleHostingView.wantsLayer = true
        bubbleHostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let menuRoot = OverlayMenuControlRootView()
            .environmentObject(store)
            .environmentObject(controlPresentation)
            .apcInterfaceLanguage(store)
        let menuHostingView = FirstMouseHostingView(rootView: menuRoot)
        menuHostingView.wantsLayer = true
        menuHostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let screen = currentScreen(for: store)
        let visibleFrame = screen?.visibleFrame ?? fallbackVisibleFrame
        store.updateOverlayPlacement(frame: visibleFrame, visibleFrame: visibleFrame)
        let initialFrame = contentFrame(for: store, visibleFrame: visibleFrame)
        store.updateOverlayPlacement(frame: initialFrame, visibleFrame: visibleFrame)

        let panel = OverlayPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.overlayStore = store
        panel.contentView = hostingView
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = Self.companionCollectionBehavior
        panel.canHide = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true

        let bubblePanel = BubbleOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        bubblePanel.overlayStore = store
        bubblePanel.onKeyboardNavigationChanged = { [weak self] active in
            self?.controlPresentation.setFocused(.bubble, active)
        }
        bubblePanel.contentView = bubbleHostingView
        bubblePanel.level = .floating
        bubblePanel.backgroundColor = .clear
        bubblePanel.isOpaque = false
        bubblePanel.hasShadow = false
        bubblePanel.isMovable = false
        bubblePanel.ignoresMouseEvents = false
        bubblePanel.acceptsMouseMovedEvents = true
        bubblePanel.isMovableByWindowBackground = false
        bubblePanel.becomesKeyOnlyIfNeeded = false
        bubblePanel.collectionBehavior = Self.companionCollectionBehavior
        bubblePanel.canHide = true
        bubblePanel.hidesOnDeactivate = false
        bubblePanel.animationBehavior = .none
        bubblePanel.isExcludedFromWindowsMenu = true

        let menuPanel = ControlOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        menuPanel.onPrimaryAction = { [weak store] in
            store?.toggleOverlayBubble()
        }
        configureControlPanel(menuPanel, contentView: menuHostingView)

        self.panel = panel
        self.bubblePanel = bubblePanel
        self.menuPanel = menuPanel
        ensureAuxiliaryPanelAttachment(bubblePanel)
        ensureAuxiliaryPanelAttachment(menuPanel)
        updateAppearance(store.behavior.appearanceTheme)
        syncPlacement()
        startDesktopVisibilityTracking()
        hiddenForDesktop = shouldHideForFinderDesktop()
        setVisible(store.behavior.enabled)
    }

    func setVisible(_ visible: Bool) {
        if visible && !hiddenForDesktop {
            ensureAuxiliaryPanelAttachments()
            let wasVisible = panel?.isVisible == true
            fitPanelToContentFrame(ensurePosition: true, refreshPointer: true)
            if !wasVisible {
                resumeMetalRenderers(in: panel?.contentView)
                panel?.orderFront(nil)
            }
            syncBubbleVisibility()
            syncControlVisibility()
            if !wasVisible {
                (panel as? OverlayPanel)?.startPointerTracking()
            }
        } else {
            directManipulationSnapshot = nil
            bubbleAnimationGeneration &+= 1
            controlPanelFadeOutTask?.cancel()
            controlPanelFadeOutTask = nil
            controlPresentation.reset()
            pauseMetalRenderers(in: panel?.contentView)
            (panel as? OverlayPanel)?.stopPointerTracking()
            (bubblePanel as? BubbleOverlayPanel)?.stopPointerTracking()
            panel?.orderOut(nil)
            bubblePanel?.orderOut(nil)
            bubblePanel?.alphaValue = 1
            bubblePanel?.ignoresMouseEvents = false
            menuPanel?.orderOut(nil)
            menuPanel?.ignoresMouseEvents = false
        }
    }

    func updateDisplayWidth(_ displayWidthPt: CGFloat) {
        fitPanelToContentFrame(ensurePosition: true, refreshPointer: true)
        if let visibleFrame = panel?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            store?.ensureOverlayPetPosition(in: visibleFrame)
        }
        syncPlacement()
        interactionPresentation.clearDisplayWidthPreview()
        if let store {
            syncInteractionViews(
                petScreenCenter: store.overlayPresentedPetScreenCenter,
                displayWidthPt: displayWidthPt
            )
        }
        (panel as? OverlayPanel)?.refreshPointerPassthrough()
    }

    func previewDisplayWidth(
        _ displayWidthPt: CGFloat,
        petScreenCenter: CGPoint
    ) {
        guard store != nil, let panel else { return }
        let targetFrame = OverlayGeometry.petPanelScreenFrame(
            displayWidthPt: displayWidthPt,
            petScreenCenter: petScreenCenter,
            clickMenuEnabled: false
        )
        interactionPresentation.present(
            displayWidthPt: displayWidthPt,
            petLocalCenter: OverlayGeometry.localPoint(
                forScreenPoint: petScreenCenter,
                panelFrame: targetFrame,
                fallbackIn: targetFrame.size
            )
        )
        moveWindowDuringInteraction(
            panel,
            to: targetFrame
        )
        presentedPetScreenCenter = petScreenCenter
        syncInteractionViews(
            petScreenCenter: petScreenCenter,
            displayWidthPt: displayWidthPt
        )
    }

    func updateLayout(animateBubble: Bool = false) {
        fitPanelToContentFrame(
            ensurePosition: true,
            refreshPointer: true,
            animateBubble: animateBubble
        )
    }

    func updateLayoutDuringInteraction() {
        if let store {
            controlPresentation.setActive(.pet, store.overlayPetDragInProgress)
            if store.overlayPetDragInProgress {
                beginDirectManipulationIfNeeded()
            }
        }
        fitPanelToContentFrame(ensurePosition: false, refreshPointer: false)
    }

    /// Keep the high-frequency direct-drag path inside AppKit. Publishing the
    /// pet center and remeasuring every session row for each pointer event
    /// makes the whole ObservableObject and Metal-backed view hierarchy work
    /// much harder than a window translation requires.
    func presentPetDrag(at petScreenCenter: CGPoint, visibleFrame: CGRect) {
        guard let store, let panel else { return }
        beginDirectManipulationIfNeeded()
        let displayWidthPt = presentedDisplayWidthPt(for: store)
        let previousCenter = presentedPetScreenCenter
            ?? store.overlayPetScreenCenter
        let moves = OverlayDirectManipulationMovePlan.moves(
            parentFrame: panel.frame,
            previousPetCenter: previousCenter,
            presentedPetCenter: petScreenCenter
        )
        for move in moves {
            precondition(move.role == .parentPetPanel)
            moveWindowDuringInteraction(panel, to: move.frame)
        }
        presentedPetScreenCenter = petScreenCenter
        syncInteractionViews(
            petScreenCenter: petScreenCenter,
            displayWidthPt: displayWidthPt
        )
    }

    func updateAppearance(_ theme: AppearanceTheme) {
        let appearance = APCApplicationAppearance.nsAppearance(for: theme)
        for window in [panel, bubblePanel, menuPanel] {
            window?.appearance = appearance
        }
    }

    func controlCenterDidOpen() {
        desktopVisibilityPolicy.controlCenterDidOpen()
    }

    func controlCenterDidClose() {
        desktopVisibilityPolicy.controlCenterDidClose()
        hiddenForDesktop = false
        guard store?.behavior.enabled == true else { return }
        setVisible(true)
    }

    func refreshPointerPassthrough() {
        (panel as? OverlayPanel)?.refreshPointerPassthrough()
    }

    /// Enters keyboard navigation only after an explicit user command. The
    /// ordinary overlay remains non-activating and never steals focus merely
    /// because a pet or Agent state appears.
    func focusBubbleForKeyboardNavigation() {
        guard let bubblePanel, bubblePanel.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        (bubblePanel as? BubbleOverlayPanel)?.beginKeyboardNavigation()
    }

    private func firstDescendant<View: NSView>(
        of type: View.Type,
        in root: NSView
    ) -> View? {
        if let match = root as? View { return match }
        for subview in root.subviews {
            if let match = firstDescendant(of: type, in: subview) {
                return match
            }
        }
        return nil
    }

    private func ensureAuxiliaryPanelAttachments() {
        ensureAuxiliaryPanelAttachment(bubblePanel)
        ensureAuxiliaryPanelAttachment(menuPanel)
    }

    /// `orderOut` detaches AppKit child windows. Every show path therefore
    /// repairs the composition root before ordering an auxiliary panel in.
    private func ensureAuxiliaryPanelAttachment(_ auxiliary: NSWindow?) {
        guard let panel, let auxiliary, panel !== auxiliary else { return }
        OverlayAuxiliaryPanelAttachment.ensure(
            parent: panel,
            auxiliary: auxiliary
        )
    }

    private func beginDirectManipulationIfNeeded() {
        guard directManipulationSnapshot == nil, let panel else { return }
        ensureAuxiliaryPanelAttachments()
        directManipulationSnapshot = OverlayAuxiliaryRelativeFrameSnapshot.capture(
            parentFrame: panel.frame,
            bubbleFrame: bubblePanel?.isVisible == true ? bubblePanel?.frame : nil,
            menuFrame: menuPanel?.isVisible == true ? menuPanel?.frame : nil
        )
    }

    func refreshPointerDrivenControlVisibility() {
        guard let store else { return }
        controlPresentation.setHovered(.pet, store.overlayPointerNearPet)
        controlPresentation.setActive(.pet, store.overlayPetDragInProgress)
        fitControlPanels(for: store)
    }

    private func fitPanelToContentFrame(
        ensurePosition: Bool,
        refreshPointer: Bool,
        animateBubble: Bool = false
    ) {
        guard let panel, let store else { return }
        let layoutMode: OverlayCompositionLayoutMode =
            store.overlayPetDragInProgress
                ? .directManipulation
                : .resting
        if layoutMode == .directManipulation {
            beginDirectManipulationIfNeeded()
        } else {
            directManipulationSnapshot = nil
        }
        let screen = currentScreen(for: store)
        let visibleFrame = screen?.visibleFrame ?? fallbackVisibleFrame
        if ensurePosition {
            store.ensureOverlayPetPosition(in: visibleFrame)
        }
        let petScreenCenter = store.overlayPresentedPetScreenCenter
        let targetFrame = contentFrame(
            for: store,
            visibleFrame: visibleFrame,
            petScreenCenter: petScreenCenter
        )
        let presentationMatchesCommittedCenter = hypot(
            petScreenCenter.x - store.overlayPetScreenCenter.x,
            petScreenCenter.y - store.overlayPetScreenCenter.y
        ) <= 0.01
        if !store.overlayPetDragInProgress,
           presentationMatchesCommittedCenter
        {
            store.recordOverlayPanelFrame(targetFrame, visibleFrame: visibleFrame)
        }
        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: true, animate: false)
        }
        presentedPetScreenCenter = petScreenCenter
        if layoutMode == .resting {
            fitBubblePanel(
                for: store,
                visibleFrame: visibleFrame,
                petScreenCenter: petScreenCenter,
                animate: animateBubble
            )
            fitControlPanels(for: store, petScreenCenter: petScreenCenter)
        }
        if refreshPointer {
            (panel as? OverlayPanel)?.refreshPointerPassthrough()
        }
    }

    private var fallbackVisibleFrame: CGRect {
        store?.overlayScreenVisibleFrame.isEmpty == false
            ? (store?.overlayScreenVisibleFrame ?? .zero)
            : NSRect(x: 0, y: 0, width: 704, height: 640)
    }

    private func currentScreen(for store: AppStore?) -> NSScreen? {
        if
            let store,
            store.overlayPresentedPetScreenCenter != .zero,
            let screen = NSScreen.screens.first(where: {
                $0.frame.contains(store.overlayPresentedPetScreenCenter)
            })
        {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func currentVisibleFrame(for store: AppStore?) -> CGRect {
        currentScreen(for: store)?.visibleFrame ?? fallbackVisibleFrame
    }

    private func syncPlacement() {
        guard let panel else { return }
        store?.recordOverlayPanelFrame(panel.frame, visibleFrame: currentVisibleFrame(for: store))
    }

    private func contentFrame(
        for store: AppStore,
        visibleFrame _: CGRect,
        petScreenCenter: CGPoint? = nil
    ) -> CGRect {
        OverlayGeometry.petPanelScreenFrame(
            displayWidthPt: presentedDisplayWidthPt(for: store),
            petScreenCenter: petScreenCenter
                ?? store.overlayPresentedPetScreenCenter,
            clickMenuEnabled: false
        )
    }

    private func presentedDisplayWidthPt(for store: AppStore) -> CGFloat {
        interactionPresentation.resolvedDisplayWidthPt(
            fallback: store.overlayDisplayWidthPt
        )
    }

    private func syncInteractionViews(
        petScreenCenter: CGPoint,
        displayWidthPt: CGFloat
    ) {
        if let dragView = panel?.contentView.flatMap({
            firstDescendant(of: WindowDragRegion.DragView.self, in: $0)
        }) {
            dragView.petScreenCenter = petScreenCenter
            dragView.displayWidthPt = displayWidthPt
        }
    }

    private func configureControlPanel(_ panel: NSPanel, contentView: NSView) {
        panel.contentView = contentView
        // The pet canvas and its controls intentionally live in separate
        // transparent windows. A click or drag can bring the canvas panel in
        // front of siblings at the same level, leaving its transparent bounds
        // above (and intercepting) the visible control. Keep compact controls
        // one level above all overlay content so their event bridge remains the
        // first recipient regardless of which overlay window was used last.
        panel.level = ControlOverlayPanel.overlayWindowLevel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = Self.companionCollectionBehavior
        panel.canHide = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
    }

    private func fitControlPanels(
        for store: AppStore,
        petScreenCenter: CGPoint? = nil
    ) {
        guard directManipulationSnapshot == nil,
              !store.overlayPetDragInProgress else { return }
        positionControlPanelFrames(
            for: store,
            petScreenCenter: petScreenCenter
                ?? store.overlayPresentedPetScreenCenter,
            duringInteraction: false
        )

        guard panel?.isVisible == true else { return }
        let bubbleToggleVisible = OverlayBubbleTogglePresentation.content(
            sessionCount: store.overlayBubbleSessionCount,
            collapsed: store.overlayBubbleIsCollapsed
        ) != nil
        if controlPresentation.isVisible {
            controlPanelFadeOutTask?.cancel()
            controlPanelFadeOutTask = nil
            menuPanel?.ignoresMouseEvents = false
        }

        if store.behavior.clickMenu && bubbleToggleVisible && controlPresentation.isVisible {
            if menuPanel?.isVisible != true {
                ensureAuxiliaryPanelAttachment(menuPanel)
                menuPanel?.orderFront(nil)
            }
        } else if controlPresentation.isVisible, menuPanel?.isVisible == true {
            menuPanel?.orderOut(nil)
        }
        if controlPresentation.isVisible { return }

        // Keep the panels interactive while they fade. Re-entering a control
        // can therefore cancel the transition instead of producing a brief
        // dead region after the pointer returns.
        let hasVisibleControlPanel = menuPanel?.isVisible == true
        guard hasVisibleControlPanel, controlPanelFadeOutTask == nil else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            menuPanel?.orderOut(nil)
            return
        }
        controlPanelFadeOutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: OverlayMotion.controlFadeDelay)
            guard let self, !Task.isCancelled else { return }
            guard !self.controlPresentation.isVisible else {
                self.controlPanelFadeOutTask = nil
                return
            }
            self.menuPanel?.orderOut(nil)
            self.controlPanelFadeOutTask = nil
        }
    }

    private func positionControlPanelFrames(
        for store: AppStore,
        petScreenCenter: CGPoint,
        duringInteraction: Bool
    ) {
        let menuFrame = OverlayGeometry.rect(
            center: OverlayGeometry.menuScreenCenter(
                petScreenCenter: petScreenCenter,
                displayWidthPt: presentedDisplayWidthPt(for: store),
                petVisualEnvelope: store.overlayPetVisualEnvelope
            ),
            size: OverlayGeometry.menuHitSize
        )
        let positionedMenuFrame = duringInteraction ? menuFrame : menuFrame.integral

        if let menuPanel, menuPanel.frame != positionedMenuFrame {
            if duringInteraction {
                moveWindowDuringInteraction(menuPanel, to: positionedMenuFrame)
            } else {
                menuPanel.setFrame(positionedMenuFrame, display: true, animate: false)
            }
        }
    }

    private func syncControlVisibility() {
        guard let store else { return }
        fitControlPanels(for: store)
    }

    private func fitBubblePanel(
        for store: AppStore,
        visibleFrame: CGRect,
        petScreenCenter: CGPoint? = nil,
        animate: Bool = false
    ) {
        guard directManipulationSnapshot == nil,
              !store.overlayPetDragInProgress else { return }
        guard let bubblePanel else { return }
        guard shouldShowBubble(for: store) else {
            hideBubblePanel(bubblePanel, animated: animate)
            return
        }

        let bubbleContents = store.overlayBubbleContents
        let bubbleLayout = OverlayGeometry.bubblePanelLayout(
            displayWidthPt: presentedDisplayWidthPt(for: store),
            petScreenCenter: petScreenCenter
                ?? store.overlayPresentedPetScreenCenter,
            visibleFrame: visibleFrame,
            contents: bubbleContents,
            petVisualEnvelope: store.overlayPetVisualEnvelope,
            previousDirection: bubbleAnchorDirection
        )
        let targetFrame = bubbleLayout.frame
        bubbleAnchorDirection = bubbleLayout.direction
        guard panel?.isVisible == true else {
            bubbleAnimationGeneration &+= 1
            bubblePanel.alphaValue = 1
            bubblePanel.ignoresMouseEvents = false
            bubblePanel.setFrame(targetFrame, display: true, animate: false)
            if bubblePanel.isVisible {
                (bubblePanel as? BubbleOverlayPanel)?.stopPointerTracking()
                bubblePanel.orderOut(nil)
            }
            return
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !bubblePanel.isVisible {
            showBubblePanel(
                bubblePanel,
                targetFrame: targetFrame,
                animated: animate,
                reduceMotion: reduceMotion
            )
        } else if animate && reduceMotion {
            crossfadeBubblePanel(bubblePanel, targetFrame: targetFrame)
        } else {
            bubbleAnimationGeneration &+= 1
            bubblePanel.alphaValue = 1
            bubblePanel.ignoresMouseEvents = false
            guard bubblePanel.frame != targetFrame else { return }
            if animate {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = OverlayMotion.bubbleLayoutDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    context.allowsImplicitAnimation = true
                    bubblePanel.animator().setFrame(targetFrame, display: true)
                }
            } else {
                bubblePanel.setFrame(targetFrame, display: true, animate: false)
            }
        }
    }

    private func showBubblePanel(
        _ bubblePanel: NSPanel,
        targetFrame: CGRect,
        animated: Bool,
        reduceMotion: Bool
    ) {
        bubbleAnimationGeneration &+= 1
        bubblePanel.setFrame(targetFrame, display: true, animate: false)
        bubblePanel.ignoresMouseEvents = false
        bubblePanel.alphaValue = animated ? 0 : 1
        ensureAuxiliaryPanelAttachment(bubblePanel)
        bubblePanel.orderFront(nil)
        (bubblePanel as? BubbleOverlayPanel)?.startPointerTracking()
        guard animated else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion
                ? OverlayMotion.reducedMotionCrossfadeDuration
                : OverlayMotion.bubbleLayoutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            bubblePanel.animator().alphaValue = 1
        }
    }

    private func hideBubblePanel(_ bubblePanel: NSPanel, animated: Bool) {
        guard bubblePanel.isVisible else {
            bubbleAnimationGeneration &+= 1
            bubblePanel.alphaValue = 1
            bubblePanel.ignoresMouseEvents = false
            return
        }

        bubbleAnimationGeneration &+= 1
        let generation = bubbleAnimationGeneration
        guard animated else {
            (bubblePanel as? BubbleOverlayPanel)?.stopPointerTracking()
            bubblePanel.orderOut(nil)
            bubblePanel.alphaValue = 1
            return
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = reduceMotion
            ? OverlayMotion.reducedMotionCrossfadeDuration
            : OverlayMotion.bubbleLayoutDuration
        let delay = reduceMotion
            ? OverlayMotion.reducedMotionCrossfadeDelay
            : OverlayMotion.bubbleLayoutDelay
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            bubblePanel.animator().alphaValue = 0
        }
        Task { @MainActor [weak self, weak bubblePanel] in
            try? await Task.sleep(for: delay)
            guard let self, let bubblePanel, !Task.isCancelled else { return }
            guard self.bubbleAnimationGeneration == generation else { return }
            (bubblePanel as? BubbleOverlayPanel)?.stopPointerTracking()
            bubblePanel.orderOut(nil)
            bubblePanel.alphaValue = 1
        }
    }

    /// Reduce Motion uses a whole-panel fade-through. The old frame stays in
    /// place until fully transparent, then the new layout is installed and
    /// faded back in, so collapsing rows are never clipped by an early resize.
    private func crossfadeBubblePanel(_ bubblePanel: NSPanel, targetFrame: CGRect) {
        bubbleAnimationGeneration &+= 1
        let generation = bubbleAnimationGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = OverlayMotion.reducedMotionCrossfadeDuration / 2
            context.allowsImplicitAnimation = true
            bubblePanel.animator().alphaValue = 0
        }
        Task { @MainActor [weak self, weak bubblePanel] in
            try? await Task.sleep(for: OverlayMotion.reducedMotionCrossfadeHalfDelay)
            guard let self, let bubblePanel, !Task.isCancelled else { return }
            guard self.bubbleAnimationGeneration == generation else { return }
            bubblePanel.setFrame(targetFrame, display: true, animate: false)
            bubblePanel.alphaValue = 0
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = OverlayMotion.reducedMotionCrossfadeDuration / 2
            NSAnimationContext.current.allowsImplicitAnimation = true
            bubblePanel.animator().alphaValue = 1
            NSAnimationContext.endGrouping()
            try? await Task.sleep(for: OverlayMotion.reducedMotionCrossfadeHalfDelay)
            guard !Task.isCancelled else { return }
            guard self.bubbleAnimationGeneration == generation else { return }
            bubblePanel.alphaValue = 1
        }
    }

    private func syncBubbleVisibility() {
        guard let store else { return }
        fitBubblePanel(for: store, visibleFrame: currentVisibleFrame(for: store))
    }

    private func moveWindowDuringInteraction(
        _ window: NSWindow,
        to targetFrame: CGRect
    ) {
        guard window.frame != targetFrame else { return }
        if window.frame.size == targetFrame.size {
            window.setFrameOrigin(targetFrame.origin)
        } else {
            window.setFrame(targetFrame, display: true, animate: false)
        }
    }

    private func shouldShowBubble(for store: AppStore) -> Bool {
        !store.overlayBubbleContents.isEmpty
    }

    private static var companionCollectionBehavior: NSWindow.CollectionBehavior {
        [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    private func startDesktopVisibilityTracking() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let activationObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateDesktopVisibility()
            }
        }
        let spaceObserver = center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateDesktopVisibility()
            }
        }
        let appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateDesktopVisibility()
            }
        }
        let appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateDesktopVisibility()
            }
        }
        workspaceObservers = [activationObserver, spaceObserver, appActivationObserver, appResignObserver]

        // Workspace/space/activation notifications are the primary signal.
        // This low-frequency fallback covers Show Desktop transitions that do
        // not reliably emit one, without continuously querying WindowServer.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateDesktopVisibility()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        desktopVisibilityTimer = timer
    }

    private func updateDesktopVisibility() {
        // A disabled overlay is already ordered out and has no desktop
        // visibility state to maintain. In particular, avoid the relatively
        // expensive CGWindowListCopyWindowInfo call on the <1% hidden path.
        guard store?.behavior.enabled == true else { return }
        let shouldHide = shouldHideForFinderDesktop()
        let shouldRestore = !shouldHide && (hiddenForDesktop || (store?.behavior.enabled == true && panel?.isVisible == false))
        guard hiddenForDesktop != shouldHide || shouldRestore else { return }
        hiddenForDesktop = shouldHide
        setVisible(store?.behavior.enabled ?? false)
    }

    private func shouldHideForFinderDesktop() -> Bool {
        guard desktopVisibilityPolicy.controlCenterIsOpen,
              !PetRendererTelemetry.isRequested
        else {
            return false
        }
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let frontmostApplicationIsFinder =
            frontmostApplication?.bundleIdentifier == "com.apple.finder"
        let regularWindows = visibleRegularApplicationWindows()
        let finderHasRegularWindow = if frontmostApplicationIsFinder,
                                        let frontmostApplication {
            regularWindows.contains { info in
                (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                    == frontmostApplication.processIdentifier
            }
        } else {
            false
        }
        return desktopVisibilityPolicy.shouldHide(
            rendererValidationActive: false,
            frontmostApplicationIsFinder: frontmostApplicationIsFinder,
            finderHasRegularWindow: finderHasRegularWindow,
            hasVisibleRegularApplicationWindow:
                !regularWindows.isEmpty
        )
    }

    private func visibleRegularApplicationWindows() -> [[String: Any]] {
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return windows.filter { info in
            guard
                (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
            else {
                return false
            }
            let owner = (info[kCGWindowOwnerName as String] as? String) ?? ""
            guard owner != "Dock", owner != "WindowManager", owner != "SystemUIServer" else { return false }
            let name = (info[kCGWindowName as String] as? String) ?? ""
            guard !name.localizedCaseInsensitiveContains("desktop") else { return false }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0 else { return false }
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return false }
            let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
            let looksLikeScreenBackdrop = NSScreen.screens.contains { screen in
                abs(width - screen.frame.width) < 4 && abs(height - screen.frame.height) < 4
            }
            return width > 80 && height > 80 && !looksLikeScreenBackdrop
        }
    }

    private func pauseMetalRenderers(in view: NSView?) {
        guard let view else { return }
        if let metalView = view as? MTKView {
            metalView.isPaused = true
            (metalView.delegate as? PetRendererLifecycle)?.suspendPipeline()
        }
        for subview in view.subviews {
            pauseMetalRenderers(in: subview)
        }
    }

    private func resumeMetalRenderers(in view: NSView?) {
        guard let view else { return }
        if let metalView = view as? MTKView {
            (metalView.delegate as? PetRendererLifecycle)?.resumePipeline(in: metalView)
        }
        for subview in view.subviews {
            resumeMetalRenderers(in: subview)
        }
    }
}

final class BubbleOverlayPanel: NSPanel {
    weak var overlayStore: AppStore?
    var onKeyboardNavigationChanged: ((Bool) -> Void)?
    private let pointerMonitor = OverlayPointerEventMonitor()
    private var clickMenuTarget: BubbleClickMenuTarget?

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performDrag(with event: NSEvent) {}

    func startPointerTracking() {
        acceptsMouseMovedEvents = true
        guard !pointerMonitor.isRunning else {
            refreshPointerPassthrough()
            return
        }
        pointerMonitor.start { [weak self] in self?.refreshPointerPassthrough() }
        refreshPointerPassthrough()
    }

    func stopPointerTracking() {
        pointerMonitor.stop()
        setIgnoresMouseEventsIfNeeded(false)
    }

    func refreshPointerPassthrough() {
        guard pointerMonitor.isRunning else { return }
        if overlayStore?.overlayPetDragInProgress == true {
            return
        }
        guard !isKeyWindow else {
            setIgnoresMouseEventsIfNeeded(false)
            return
        }
        guard overlayStore?.behavior.mousePassthrough ?? true else {
            setIgnoresMouseEventsIfNeeded(false)
            return
        }
        setIgnoresMouseEventsIfNeeded(!shouldHandleMouse(screenPoint: NSEvent.mouseLocation))
    }

    func beginKeyboardNavigation() {
        setIgnoresMouseEventsIfNeeded(false)
        makeKeyAndOrderFront(nil)
        _ = makeFirstResponder(contentView)
        selectNextKeyView(nil)
    }

    override func becomeKey() {
        super.becomeKey()
        setIgnoresMouseEventsIfNeeded(false)
        onKeyboardNavigationChanged?(true)
    }

    override func resignKey() {
        super.resignKey()
        onKeyboardNavigationChanged?(false)
        refreshPointerPassthrough()
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard shouldHandleMouse(localPoint: event.locationInWindow) else {
                setIgnoresMouseEventsIfNeeded(true)
                return
            }
            setIgnoresMouseEventsIfNeeded(false)
            if event.type == .leftMouseDown, handleActionClick(at: event.locationInWindow) {
                return
            }
            if event.type == .rightMouseDown, handleContextMenu(with: event) {
                return
            }
        default:
            break
        }
        super.sendEvent(event)

        switch event.type {
        case .mouseMoved, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            refreshPointerPassthrough()
        default:
            break
        }
    }

    private func shouldHandleMouse(screenPoint: NSPoint) -> Bool {
        if let overlayStore,
           overlayStore.overlayVisible,
           overlayStore.overlayActivePointerInteractionID != nil {
            return true
        }
        guard frame.contains(screenPoint) else { return false }
        guard overlayStore?.behavior.mousePassthrough ?? true else { return true }
        return shouldHandleMouse(localPoint: CGPoint(
            x: screenPoint.x - frame.minX,
            y: screenPoint.y - frame.minY
        ))
    }

    private func shouldHandleMouse(localPoint: NSPoint) -> Bool {
        guard overlayStore?.behavior.mousePassthrough ?? true else { return true }
        let topLeftPoint = CGPoint(x: localPoint.x, y: frame.height - localPoint.y)
        return bubbleRects().contains { rect in
            roundedRectContains(topLeftPoint, in: rect, radius: OverlayGeometry.bubbleCornerRadius)
        }
    }

    private func handleActionClick(at location: NSPoint) -> Bool {
        guard let overlayStore else { return false }
        guard let (content, rect, topLeftPoint) = bubbleHit(at: location) else { return false }

        if OverlayGeometry.bubbleGroupToggleHitRect(in: rect, content: content)
            .contains(topLeftPoint),
           let source = content.source
        {
            overlayStore.toggleOverlayAgentGroup(source)
            return true
        }

        if let session = sessionHit(in: content, bubbleRect: rect, point: topLeftPoint),
           OverlaySessionPrimaryClickPolicy.shouldActivate(session) {
            overlayStore.activateOverlaySession(session)
            return true
        }

        if content.canDismiss,
           OverlayGeometry.bubbleCloseHitRect(in: rect).contains(topLeftPoint)
        {
            overlayStore.dismissOverlayBubble(eventIDs: content.dismissalIDs)
            return true
        }

        return false
    }

    private func handleContextMenu(with event: NSEvent) -> Bool {
        guard let overlayStore, let contentView else { return false }
        guard let (content, rect, topLeftPoint) = bubbleHit(at: event.locationInWindow) else {
            return false
        }
        let session = sessionHit(in: content, bubbleRect: rect, point: topLeftPoint)

        let target = BubbleClickMenuTarget(
            onOpenSession: { [weak overlayStore] in
                guard let session else { return }
                overlayStore?.activateOverlaySession(session)
            },
            onDismiss: { [weak overlayStore] in
                if let session {
                    overlayStore?.dismissOverlayBubble(eventID: session.id)
                } else {
                    overlayStore?.dismissOverlayBubble(eventIDs: content.dismissalIDs)
                }
            }
        )
        clickMenuTarget = target

        let menu = NSMenu()
        menu.appearance = APCApplicationAppearance.nsAppearance(
            for: overlayStore.behavior.appearanceTheme
        )
        if let session, session.canOpen {
            let openItem = NSMenuItem(
                title: session.actionLabel,
                action: #selector(BubbleClickMenuTarget.openSession),
                keyEquivalent: ""
            )
            openItem.target = target
            openItem.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
            menu.addItem(openItem)
        }

        if content.canDismiss {
            let dismissItem = NSMenuItem(
                title: APCLocalization.text(
                    session == nil ? .overlayCollapseBubble : .overlayDismissSession
                ),
                action: #selector(BubbleClickMenuTarget.dismissBubble),
                keyEquivalent: ""
            )
            dismissItem.target = target
            dismissItem.image = NSImage(
                systemSymbolName: session == nil ? "chevron.down" : "minus.circle",
                accessibilityDescription: nil
            )
            menu.addItem(dismissItem)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: contentView)
        return true
    }

    private func sessionHit(
        in content: OverlayBubbleContent,
        bubbleRect: CGRect,
        point: CGPoint
    ) -> OverlaySessionContent? {
        zip(
            content.visibleSessions,
            OverlayGeometry.bubbleSessionRects(in: bubbleRect, content: content)
        )
        .first(where: { pair in pair.1.contains(point) })?
        .0
    }

    private func bubbleHit(at location: NSPoint) -> (
        content: OverlayBubbleContent,
        rect: CGRect,
        topLeftPoint: CGPoint
    )? {
        guard let overlayStore else { return nil }
        let topLeftPoint = CGPoint(x: location.x, y: frame.height - location.y)
        for (content, rect) in zip(overlayStore.overlayBubbleContents, bubbleRects())
        where roundedRectContains(topLeftPoint, in: rect, radius: OverlayGeometry.bubbleCornerRadius) {
            return (content, rect, topLeftPoint)
        }
        return nil
    }

    private func bubbleRects() -> [CGRect] {
        guard let overlayStore else { return [] }
        let visibleFrame = screen?.visibleFrame ?? overlayStore.overlayScreenVisibleFrame
        let contents = overlayStore.overlayBubbleContents
        let alignLeft = OverlayGeometry.bubbleAlignsLeft(
            petScreenCenter: overlayStore.overlayPresentedPetScreenCenter,
            screenFrame: visibleFrame
        )
        return OverlayGeometry.bubbleRects(
            inPanelSize: frame.size,
            visibleFrameSize: visibleFrame.size,
            contents: contents,
            alignLeft: alignLeft
        )
    }

    private func roundedRectContains(_ point: CGPoint, in rect: CGRect, radius: CGFloat) -> Bool {
        guard rect.contains(point) else { return false }
        let radius = min(radius, rect.width / 2, rect.height / 2)
        if rect.insetBy(dx: radius, dy: 0).contains(point)
            || rect.insetBy(dx: 0, dy: radius).contains(point) {
            return true
        }

        let corners = [
            CGPoint(x: rect.minX + radius, y: rect.minY + radius),
            CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
            CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
            CGPoint(x: rect.maxX - radius, y: rect.maxY - radius)
        ]
        return corners.contains { corner in
            hypot(point.x - corner.x, point.y - corner.y) <= radius
        }
    }

    private func setIgnoresMouseEventsIfNeeded(_ value: Bool) {
        if ignoresMouseEvents != value {
            ignoresMouseEvents = value
        }
    }
}

final class ControlOverlayPanel: NSPanel {
    static let overlayWindowLevel = NSWindow.Level(
        rawValue: NSWindow.Level.floating.rawValue + 1
    )

    var onPrimaryAction: (() -> Void)?
    var onKeyStatusChanged: ((Bool) -> Void)?
    private var primaryActionArmed = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        onKeyStatusChanged?(true)
    }

    override func resignKey() {
        super.resignKey()
        onKeyStatusChanged?(false)
    }

    override func performDrag(with event: NSEvent) {}

    override func sendEvent(_ event: NSEvent) {
        guard onPrimaryAction != nil else {
            super.sendEvent(event)
            return
        }

        switch event.type {
        case .leftMouseDown:
            guard primaryActionContains(event.locationInWindow) else {
                primaryActionArmed = false
                super.sendEvent(event)
                return
            }
            // A SwiftUI Button hosted by a non-activating NSPanel can lose its
            // first click while AppKit resolves activation. Own this compact
            // mouse sequence at the panel boundary so the control remains
            // usable without activating the app or stealing focus.
            primaryActionArmed = true
            return
        case .leftMouseDragged:
            if primaryActionArmed {
                return
            }
        case .leftMouseUp:
            guard primaryActionArmed else { break }
            primaryActionArmed = false
            if primaryActionContains(event.locationInWindow) {
                onPrimaryAction?()
            }
            return
        default:
            break
        }

        super.sendEvent(event)
    }

    private func primaryActionContains(_ point: NSPoint) -> Bool {
        contentView?.frame.contains(point) ?? false
    }
}

private final class OverlayPanel: NSPanel {
    weak var overlayStore: AppStore?
    private let pointerMonitor = OverlayPointerEventMonitor()

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performDrag(with event: NSEvent) {}

    func startPointerTracking() {
        acceptsMouseMovedEvents = true
        guard !pointerMonitor.isRunning else {
            refreshPointerPassthrough()
            return
        }
        pointerMonitor.start { [weak self] in self?.refreshPointerPassthrough() }
        refreshPointerPassthrough()
    }

    func stopPointerTracking() {
        pointerMonitor.stop()
        overlayStore?.cancelOverlayPointerInteractions()
        overlayStore?.setOverlayPointerNearPet(false)
        setIgnoresMouseEventsIfNeeded(false)
    }

    func refreshPointerPassthrough() {
        guard pointerMonitor.isRunning else { return }
        let mouseLocation = NSEvent.mouseLocation
        var pointerInActivationZone = false
        if let overlayStore {
            overlayStore.reconcileOverlayPointerInteractions(
                pressedMouseButtons: NSEvent.pressedMouseButtons
            )
            pointerInActivationZone = shouldHandleMouse(screenPoint: mouseLocation)
            overlayStore.setOverlayPointerNearPet(OverlayGeometry.shouldShowControls(
                at: mouseLocation,
                displayWidthPt: overlayStore.overlayDisplayWidthPt,
                petScreenCenter: overlayStore.overlayPresentedPetScreenCenter,
                clickMenuEnabled: overlayStore.behavior.clickMenu,
                petVisualEnvelope: overlayStore.overlayPetVisualEnvelope
            ))
        }
        guard overlayStore?.behavior.mousePassthrough ?? true else {
            setIgnoresMouseEventsIfNeeded(false)
            return
        }
        // Activate before the pointer reaches a compact control. Waiting until
        // it is inside the exact 36/38pt target races the asynchronous global
        // mouse monitor and lets the first click fall through to another app.
        setIgnoresMouseEventsIfNeeded(!pointerInActivationZone)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let shouldHandle = shouldHandleMouse(localPoint: event.locationInWindow)
            if !shouldHandle {
                setIgnoresMouseEventsIfNeeded(true)
                return
            }
            setIgnoresMouseEventsIfNeeded(false)
        default:
            break
        }

        super.sendEvent(event)

        switch event.type {
        case .mouseMoved:
            refreshPointerPassthrough()
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            refreshPointerPassthrough()
        default:
            break
        }
    }

    private func shouldHandleMouse(screenPoint: NSPoint) -> Bool {
        guard frame.contains(screenPoint) else { return false }
        guard overlayStore?.behavior.mousePassthrough ?? true else { return true }
        let localPoint = CGPoint(
            x: screenPoint.x - frame.minX,
            y: screenPoint.y - frame.minY
        )
        return shouldHandleMouse(localPoint: localPoint)
    }

    private func shouldHandleMouse(localPoint: NSPoint) -> Bool {
        guard let overlayStore else { return false }
        guard overlayStore.behavior.mousePassthrough else { return true }

        let containerSize = CGSize(width: frame.width, height: frame.height)
        let topLeftPoint = CGPoint(x: localPoint.x, y: containerSize.height - localPoint.y)
        let bubbleVisible = !overlayStore.overlayBubbleContents.isEmpty
        let petCenter = OverlayGeometry.localPoint(
            forScreenPoint: overlayStore.overlayPresentedPetScreenCenter,
            panelFrame: frame,
            fallbackIn: containerSize
        )

        return OverlayGeometry.shouldHandleMouse(
            atTopLeftPoint: topLeftPoint,
            in: containerSize,
            displayWidthPt: overlayStore.overlayDisplayWidthPt,
            petCenter: petCenter,
            bubbleVisible: bubbleVisible,
            clickMenuEnabled: overlayStore.behavior.clickMenu,
            panelFrame: frame,
            screenFrame: screen?.visibleFrame ?? overlayStore.overlayScreenVisibleFrame,
            includeBubble: false,
            mousePassthroughEnabled: overlayStore.behavior.mousePassthrough,
            petFrameHitTest: overlayStore.overlayPetFrameHitTest,
            overlayVisible: overlayStore.overlayVisible,
            primaryButtonDown: NSEvent.pressedMouseButtons & 1 != 0,
            activeInteractionID: overlayStore.overlayActivePointerInteractionID,
            maskState: overlayStore.overlayPetPointerMaskState
        )
    }

    private func setIgnoresMouseEventsIfNeeded(_ value: Bool) {
        if ignoresMouseEvents != value {
            ignoresMouseEvents = value
        }
    }
}

@MainActor
final class OverlayPointerEventMonitor {
    static let eventMask: NSEvent.EventTypeMask = [
        .mouseMoved,
        .leftMouseUp,
        .rightMouseUp,
        .otherMouseUp
    ]

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var handler: (() -> Void)?

    var isRunning: Bool { localMonitor != nil || globalMonitor != nil }
    let usesPolling = false

    func start(handler: @escaping () -> Void) {
        self.handler = handler
        guard !isRunning else { return }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.eventMask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handler?()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.eventMask) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handler?() }
        }
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        localMonitor = nil
        globalMonitor = nil
        handler = nil
    }
}

private final class PassthroughOverlayHostingView<Content: View>: NSHostingView<Content> {
    private weak var store: AppStore?
    private let includeBubble: Bool

    init(rootView: Content, store: AppStore, includeBubble: Bool) {
        self.store = store
        self.includeBubble = includeBubble
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init(rootView: Content) {
        fatalError("Use init(rootView:store:) for overlay hit testing.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for overlay hit testing.")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if store?.behavior.mousePassthrough == false {
            return super.hitTest(point)
        }
        guard shouldHandleMouse(at: point) else { return nil }
        return super.hitTest(point)
    }

    private func shouldHandleMouse(at point: NSPoint) -> Bool {
        guard let store else { return false }

        let topLeftPoint = OverlayGeometry.topLeftPoint(
            forViewPoint: point,
            in: bounds.height,
            isFlipped: isFlipped
        )
        let size = CGSize(width: bounds.width, height: bounds.height)
        let bubbleVisible = !store.overlayBubbleContents.isEmpty
        let panelFrame = window?.frame ?? store.overlayScreenFrame
        let petCenter = OverlayGeometry.localPoint(
            forScreenPoint: store.overlayPresentedPetScreenCenter,
            panelFrame: panelFrame,
            fallbackIn: size
        )
        return OverlayGeometry.shouldHandleMouse(
            atTopLeftPoint: topLeftPoint,
            in: size,
            displayWidthPt: store.overlayDisplayWidthPt,
            petCenter: petCenter,
            bubbleVisible: bubbleVisible,
            clickMenuEnabled: store.behavior.clickMenu,
            panelFrame: panelFrame,
            screenFrame: window?.screen?.visibleFrame ?? store.overlayScreenVisibleFrame,
            includeBubble: includeBubble,
            mousePassthroughEnabled: store.behavior.mousePassthrough,
            petFrameHitTest: store.overlayPetFrameHitTest,
            overlayVisible: store.overlayVisible,
            primaryButtonDown: NSEvent.pressedMouseButtons & 1 != 0,
            activeInteractionID: store.overlayActivePointerInteractionID,
            maskState: store.overlayPetPointerMaskState
        )
    }
}

private final class BubbleClickMenuTarget: NSObject {
    private let onOpenSession: () -> Void
    private let onDismiss: () -> Void

    init(onOpenSession: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.onOpenSession = onOpenSession
        self.onDismiss = onDismiss
    }

    @objc func openSession() {
        onOpenSession()
    }

    @objc func dismissBubble() {
        onDismiss()
    }
}

private final class PassthroughBubbleHostingView<Content: View>: NSHostingView<Content> {
    private weak var store: AppStore?

    init(rootView: Content, store: AppStore) {
        self.store = store
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init(rootView: Content) {
        fatalError("Use init(rootView:store:) for bubble hit testing.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for bubble hit testing.")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if store?.behavior.mousePassthrough == false {
            return super.hitTest(point)
        }
        guard roundedBubbleContains(point) else { return nil }
        return super.hitTest(point)
    }

    private func roundedBubbleContains(_ point: NSPoint) -> Bool {
        guard let store else { return false }
        let size = CGSize(width: bounds.width, height: bounds.height)
        guard size.width > 0, size.height > 0 else { return false }
        let topLeftPoint = OverlayGeometry.topLeftPoint(
            forViewPoint: point,
            in: bounds.height,
            isFlipped: isFlipped
        )
        let visibleFrame = window?.screen?.visibleFrame ?? store.overlayScreenVisibleFrame
        let contents = store.overlayBubbleContents
        let alignLeft = OverlayGeometry.bubbleAlignsLeft(
            petScreenCenter: store.overlayPresentedPetScreenCenter,
            screenFrame: visibleFrame
        )
        return OverlayGeometry.bubbleRects(
            inPanelSize: size,
            visibleFrameSize: visibleFrame.size,
            contents: contents,
            alignLeft: alignLeft
        )
        .contains { rect in
            roundedRectContains(topLeftPoint, in: rect, radius: OverlayGeometry.bubbleCornerRadius)
        }
    }

    private func roundedRectContains(_ point: CGPoint, in rect: CGRect, radius: CGFloat) -> Bool {
        guard rect.contains(point) else { return false }
        let radius = min(radius, rect.width / 2, rect.height / 2)
        if rect.insetBy(dx: radius, dy: 0).contains(point)
            || rect.insetBy(dx: 0, dy: radius).contains(point) {
            return true
        }

        let corners = [
            CGPoint(x: rect.minX + radius, y: rect.minY + radius),
            CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
            CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
            CGPoint(x: rect.maxX - radius, y: rect.maxY - radius)
        ]
        return corners.contains { corner in
            hypot(point.x - corner.x, point.y - corner.y) <= radius
        }
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }
}
