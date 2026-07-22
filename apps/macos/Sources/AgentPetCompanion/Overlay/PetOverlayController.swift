import AgentPetCompanionCore
import AppKit
import CoreGraphics
import MetalKit
import SwiftUI

@MainActor
final class PetOverlayController {
    private var panel: NSPanel?
    private var bubblePanel: NSPanel?
    private var menuPanel: NSPanel?
    private var resizePanel: NSPanel?
    private weak var store: AppStore?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var desktopVisibilityTimer: Timer?
    private var hiddenForDesktop = false
    private let controlPresentation = OverlayControlPresentationState()
    private var controlPanelFadeOutTask: Task<Void, Never>?
    private var bubbleAnimationGeneration: UInt = 0

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
        let hostingView = PassthroughOverlayHostingView(rootView: root, store: store, includeBubble: false)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let bubbleRoot = BubbleOverlayRootView()
            .environmentObject(store)
            .environmentObject(controlPresentation)
        let bubbleHostingView = PassthroughBubbleHostingView(rootView: bubbleRoot, store: store)
        bubbleHostingView.wantsLayer = true
        bubbleHostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let menuRoot = OverlayMenuControlRootView()
            .environmentObject(store)
            .environmentObject(controlPresentation)
        let menuHostingView = FirstMouseHostingView(rootView: menuRoot)
        menuHostingView.wantsLayer = true
        menuHostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let resizeRoot = OverlayResizeControlRootView()
            .environmentObject(store)
            .environmentObject(controlPresentation)
        let resizeHostingView = FirstMouseHostingView(rootView: resizeRoot)
        resizeHostingView.wantsLayer = true
        resizeHostingView.layer?.backgroundColor = NSColor.clear.cgColor

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

        let resizePanel = ControlOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        resizePanel.onKeyStatusChanged = { [weak self] active in
            self?.controlPresentation.setFocused(.resize, active)
        }
        configureControlPanel(resizePanel, contentView: resizeHostingView)

        self.panel = panel
        self.bubblePanel = bubblePanel
        self.menuPanel = menuPanel
        self.resizePanel = resizePanel
        updateAppearance(store.behavior.appearanceTheme)
        syncPlacement()
        startDesktopVisibilityTracking()
        hiddenForDesktop = shouldHideForFinderDesktop()
        setVisible(store.behavior.enabled)
    }

    func setVisible(_ visible: Bool) {
        if visible && !hiddenForDesktop {
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
            resizePanel?.orderOut(nil)
            menuPanel?.ignoresMouseEvents = false
            resizePanel?.ignoresMouseEvents = false
        }
    }

    func updateScale(_ scale: CGFloat) {
        fitPanelToContentFrame(ensurePosition: true, refreshPointer: true)
        if let visibleFrame = panel?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            store?.ensureOverlayPetPosition(in: visibleFrame)
        }
        syncPlacement()
        (panel as? OverlayPanel)?.refreshPointerPassthrough()
    }

    func updateScaleDuringInteraction(_ scale: CGFloat) {
        fitPanelToContentFrame(ensurePosition: false, refreshPointer: false)
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
            controlPresentation.setActive(.resize, store.overlayResizeInProgress)
        }
        fitPanelToContentFrame(ensurePosition: false, refreshPointer: false)
    }

    func updateAppearance(_ theme: AppearanceTheme) {
        let appearance = APCApplicationAppearance.nsAppearance(for: theme)
        for window in [panel, bubblePanel, menuPanel, resizePanel] {
            window?.appearance = appearance
        }
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

    func focusResizeForKeyboardNavigation() {
        guard panel?.isVisible == true else { return }
        NSApp.activate(ignoringOtherApps: true)
        controlPresentation.setFocused(.resize, true)
        guard let resizePanel else { return }
        resizePanel.makeKeyAndOrderFront(nil)
        if let candidate = resizePanel.contentView.flatMap({
            firstDescendant(of: OverlayResizeAccessibilityView.self, in: $0)
        }) {
            _ = resizePanel.makeFirstResponder(candidate)
        }
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

    func refreshPointerDrivenControlVisibility() {
        guard let store else { return }
        controlPresentation.setHovered(.pet, store.overlayPointerNearPet)
        controlPresentation.setActive(.pet, store.overlayPetDragInProgress)
        controlPresentation.setActive(.resize, store.overlayResizeInProgress)
        fitControlPanels(for: store)
    }

    private func fitPanelToContentFrame(
        ensurePosition: Bool,
        refreshPointer: Bool,
        animateBubble: Bool = false
    ) {
        guard let panel, let store else { return }
        let screen = currentScreen(for: store)
        let visibleFrame = screen?.visibleFrame ?? fallbackVisibleFrame
        if ensurePosition {
            store.ensureOverlayPetPosition(in: visibleFrame)
        }
        let targetFrame = contentFrame(for: store, visibleFrame: visibleFrame)
        store.recordOverlayPanelFrame(targetFrame, visibleFrame: visibleFrame)
        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: true, animate: false)
        }
        fitBubblePanel(
            for: store,
            visibleFrame: visibleFrame,
            animate: animateBubble
        )
        fitControlPanels(for: store)
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
            store.overlayPetScreenCenter != .zero,
            let screen = NSScreen.screens.first(where: { $0.frame.contains(store.overlayPetScreenCenter) })
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

    private func contentFrame(for store: AppStore, visibleFrame _: CGRect) -> CGRect {
        OverlayGeometry.petPanelScreenFrame(
            scale: store.overlayScale,
            petScreenCenter: store.overlayPetScreenCenter,
            clickMenuEnabled: false,
            includeResize: false
        )
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

    private func fitControlPanels(for store: AppStore) {
        let menuFrame = OverlayGeometry.rect(
            center: OverlayGeometry.menuScreenCenter(
                petScreenCenter: store.overlayPetScreenCenter,
                scale: store.overlayScale,
                petVisualEnvelope: store.overlayPetVisualEnvelope
            ),
            size: OverlayGeometry.menuHitSize
        ).integral
        let resizeFrame = OverlayGeometry.rect(
            center: OverlayGeometry.resizeScreenCenter(
                petScreenCenter: store.overlayPetScreenCenter,
                scale: store.overlayScale,
                petVisualEnvelope: store.overlayPetVisualEnvelope
            ),
            size: OverlayGeometry.resizeHitSize
        ).integral

        if menuPanel?.frame != menuFrame {
            menuPanel?.setFrame(menuFrame, display: true, animate: false)
        }
        if resizePanel?.frame != resizeFrame {
            resizePanel?.setFrame(resizeFrame, display: true, animate: false)
        }

        guard panel?.isVisible == true else { return }
        let bubbleToggleVisible = OverlayBubbleTogglePresentation.content(
            sessionCount: store.overlayBubbleSessionCount,
            collapsed: store.overlayBubbleIsCollapsed
        ) != nil
        if controlPresentation.isVisible {
            controlPanelFadeOutTask?.cancel()
            controlPanelFadeOutTask = nil
            menuPanel?.ignoresMouseEvents = false
            resizePanel?.ignoresMouseEvents = false
        }

        if store.behavior.clickMenu && bubbleToggleVisible && controlPresentation.isVisible {
            if menuPanel?.isVisible != true {
                menuPanel?.orderFront(nil)
            }
        } else if controlPresentation.isVisible, menuPanel?.isVisible == true {
            menuPanel?.orderOut(nil)
        }
        if controlPresentation.isVisible {
            if resizePanel?.isVisible != true {
                resizePanel?.orderFront(nil)
            }
            return
        }

        // Keep the panels alive just long enough for their SwiftUI opacity
        // transition, but stop them intercepting input while they fade. The
        // existing 300 ms hover-exit delay has already elapsed at this point.
        menuPanel?.ignoresMouseEvents = true
        resizePanel?.ignoresMouseEvents = true
        let hasVisibleControlPanel = menuPanel?.isVisible == true
            || resizePanel?.isVisible == true
        guard hasVisibleControlPanel, controlPanelFadeOutTask == nil else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            menuPanel?.orderOut(nil)
            resizePanel?.orderOut(nil)
            menuPanel?.ignoresMouseEvents = false
            resizePanel?.ignoresMouseEvents = false
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
            self.resizePanel?.orderOut(nil)
            self.menuPanel?.ignoresMouseEvents = false
            self.resizePanel?.ignoresMouseEvents = false
            self.controlPanelFadeOutTask = nil
        }
    }

    private func syncControlVisibility() {
        guard let store else { return }
        fitControlPanels(for: store)
    }

    private func fitBubblePanel(
        for store: AppStore,
        visibleFrame: CGRect,
        animate: Bool = false
    ) {
        guard let bubblePanel else { return }
        guard shouldShowBubble(for: store) else {
            hideBubblePanel(bubblePanel, animated: animate)
            return
        }

        let bubbleContents = store.overlayBubbleContents
        let targetFrame = OverlayGeometry.bubblePanelScreenFrame(
            scale: store.overlayScale,
            petScreenCenter: store.overlayPetScreenCenter,
            visibleFrame: visibleFrame,
            contents: bubbleContents,
            petVisualEnvelope: store.overlayPetVisualEnvelope
        )
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
        bubblePanel.orderFront(nil)
        (bubblePanel as? BubbleOverlayPanel)?.startPointerTracking()
        guard animated else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion
                ? OverlayMotion.reducedMotionCrossfadeDuration
                : OverlayMotion.bubbleLayoutDuration
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
        (bubblePanel as? BubbleOverlayPanel)?.stopPointerTracking()
        bubblePanel.ignoresMouseEvents = true
        guard animated else {
            bubblePanel.orderOut(nil)
            bubblePanel.alphaValue = 1
            bubblePanel.ignoresMouseEvents = false
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
            context.allowsImplicitAnimation = true
            bubblePanel.animator().alphaValue = 0
        }
        Task { @MainActor [weak self, weak bubblePanel] in
            try? await Task.sleep(for: delay)
            guard let self, let bubblePanel, !Task.isCancelled else { return }
            guard self.bubbleAnimationGeneration == generation else { return }
            bubblePanel.orderOut(nil)
            bubblePanel.alphaValue = 1
            bubblePanel.ignoresMouseEvents = false
        }
    }

    /// Reduce Motion uses a whole-panel fade-through. The old frame stays in
    /// place until fully transparent, then the new layout is installed and
    /// faded back in, so collapsing rows are never clipped by an early resize.
    private func crossfadeBubblePanel(_ bubblePanel: NSPanel, targetFrame: CGRect) {
        bubbleAnimationGeneration &+= 1
        let generation = bubbleAnimationGeneration
        bubblePanel.ignoresMouseEvents = true
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
            bubblePanel.ignoresMouseEvents = false
        }
    }

    private func syncBubbleVisibility() {
        guard let store else { return }
        fitBubblePanel(for: store, visibleFrame: currentVisibleFrame(for: store))
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
        // The explicit renderer acceptance profile must keep a real on-screen
        // MTKView alive even when the current desktop/full-screen arrangement
        // contains no layer-0 regular window. Normal app runs do not set the
        // telemetry path and continue to honor Show Desktop hiding.
        if PetRendererTelemetry.isRequested {
            return false
        }
        guard
            let app = NSWorkspace.shared.frontmostApplication,
            app.bundleIdentifier == "com.apple.finder"
        else {
            // Show Desktop can leave the overlay app active briefly while regular windows are out
            // of view, so use WindowServer visibility as the source of truth.
            return !hasVisibleRegularApplicationWindow()
        }
        return !finderHasRegularWindow(app)
    }

    private func finderHasRegularWindow(_ app: NSRunningApplication) -> Bool {
        visibleRegularApplicationWindows().contains { info in
            (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier
        }
    }

    private func hasVisibleRegularApplicationWindow() -> Bool {
        !visibleRegularApplicationWindows().isEmpty
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

        if let session = sessionHit(in: content, bubbleRect: rect, point: topLeftPoint) {
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
            petScreenCenter: overlayStore.overlayPetScreenCenter,
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
    private var interactionInProgress = false

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
        interactionInProgress = false
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
                scale: overlayStore.overlayScale,
                petScreenCenter: overlayStore.overlayPetScreenCenter,
                clickMenuEnabled: overlayStore.behavior.clickMenu,
                petVisualEnvelope: overlayStore.overlayPetVisualEnvelope
            ))
        }
        guard overlayStore?.behavior.mousePassthrough ?? true else {
            setIgnoresMouseEventsIfNeeded(false)
            return
        }
        if interactionInProgress {
            if NSEvent.pressedMouseButtons != 0 {
                setIgnoresMouseEventsIfNeeded(false)
                return
            }
            interactionInProgress = false
        }
        // Activate before the pointer reaches a compact control. Waiting until
        // it is inside the exact 36/38pt target races the asynchronous global
        // mouse monitor and lets the first click fall through to another app.
        setIgnoresMouseEventsIfNeeded(!pointerInActivationZone)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains([.command, .option]) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "=", "+":
            overlayStore?.adjustOverlayScale(by: OverlayGeometry.resizeStep)
            return true
        case "-", "_":
            overlayStore?.adjustOverlayScale(by: -OverlayGeometry.resizeStep)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let shouldHandle = shouldHandleMouse(localPoint: event.locationInWindow)
            interactionInProgress = shouldHandle
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
            if !interactionInProgress {
                refreshPointerPassthrough()
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            interactionInProgress = false
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
            forScreenPoint: overlayStore.overlayPetScreenCenter,
            panelFrame: frame,
            fallbackIn: containerSize
        )

        return OverlayGeometry.shouldHandleMouse(
            atTopLeftPoint: topLeftPoint,
            in: containerSize,
            scale: overlayStore.overlayScale,
            petCenter: petCenter,
            bubbleVisible: bubbleVisible,
            clickMenuEnabled: overlayStore.behavior.clickMenu,
            panelFrame: frame,
            screenFrame: screen?.visibleFrame ?? overlayStore.overlayScreenVisibleFrame,
            includeBubble: false,
            includeResize: true,
            mousePassthroughEnabled: overlayStore.behavior.mousePassthrough,
            petFrameHitTest: overlayStore.overlayPetFrameHitTest
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
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged,
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
            Task { @MainActor [weak self] in self?.handler?() }
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
            forScreenPoint: store.overlayPetScreenCenter,
            panelFrame: panelFrame,
            fallbackIn: size
        )
        return OverlayGeometry.shouldHandleMouse(
            atTopLeftPoint: topLeftPoint,
            in: size,
            scale: store.overlayScale,
            petCenter: petCenter,
            bubbleVisible: bubbleVisible,
            clickMenuEnabled: store.behavior.clickMenu,
            panelFrame: panelFrame,
            screenFrame: window?.screen?.visibleFrame ?? store.overlayScreenVisibleFrame,
            includeBubble: includeBubble,
            includeResize: true,
            mousePassthroughEnabled: store.behavior.mousePassthrough,
            petFrameHitTest: store.overlayPetFrameHitTest
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
            petScreenCenter: store.overlayPetScreenCenter,
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
