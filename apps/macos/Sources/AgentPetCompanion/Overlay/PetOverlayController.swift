import AppKit
import CoreGraphics
import MetalKit
import SwiftUI

@MainActor
final class PetOverlayController {
    private var panel: NSPanel?
    private var bubblePanel: NSPanel?
    private weak var store: AppStore?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var desktopVisibilityTimer: Timer?
    private var hiddenForDesktop = false

    func show(store: AppStore) {
        self.store = store
        if panel != nil {
            setVisible(store.behavior.enabled)
            return
        }

        let root = OverlayRootView()
            .environmentObject(store)
        let hostingView = PassthroughOverlayHostingView(rootView: root, store: store, includeBubble: false)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let bubbleRoot = BubbleOverlayRootView()
            .environmentObject(store)
        let bubbleHostingView = PassthroughBubbleHostingView(rootView: bubbleRoot, store: store)
        bubbleHostingView.wantsLayer = true
        bubbleHostingView.layer?.backgroundColor = NSColor.clear.cgColor

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
        bubblePanel.contentView = bubbleHostingView
        bubblePanel.level = .floating
        bubblePanel.backgroundColor = .clear
        bubblePanel.isOpaque = false
        bubblePanel.hasShadow = false
        bubblePanel.isMovable = false
        bubblePanel.ignoresMouseEvents = false
        bubblePanel.acceptsMouseMovedEvents = true
        bubblePanel.isMovableByWindowBackground = false
        bubblePanel.collectionBehavior = Self.companionCollectionBehavior
        bubblePanel.canHide = true
        bubblePanel.hidesOnDeactivate = false
        bubblePanel.animationBehavior = .none
        bubblePanel.isExcludedFromWindowsMenu = true

        self.panel = panel
        self.bubblePanel = bubblePanel
        syncPlacement()
        startDesktopVisibilityTracking()
        hiddenForDesktop = shouldHideForFinderDesktop()
        setVisible(store.behavior.enabled)
    }

    func setVisible(_ visible: Bool) {
        if visible && !hiddenForDesktop {
            fitPanelToContentFrame(ensurePosition: true, refreshPointer: true)
            resumeMetalRenderers(in: panel?.contentView)
            panel?.orderFront(nil)
            syncBubbleVisibility()
            (panel as? OverlayPanel)?.startPointerTracking()
        } else {
            pauseMetalRenderers(in: panel?.contentView)
            (panel as? OverlayPanel)?.stopPointerTracking()
            (bubblePanel as? BubbleOverlayPanel)?.stopPointerTracking()
            panel?.orderOut(nil)
            bubblePanel?.orderOut(nil)
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

    func updateLayout() {
        fitPanelToContentFrame(ensurePosition: true, refreshPointer: true)
    }

    func updateLayoutDuringInteraction() {
        fitPanelToContentFrame(ensurePosition: false, refreshPointer: false)
    }

    func refreshPointerPassthrough() {
        (panel as? OverlayPanel)?.refreshPointerPassthrough()
    }

    private func fitPanelToContentFrame(ensurePosition: Bool, refreshPointer: Bool) {
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
        fitBubblePanel(for: store, visibleFrame: visibleFrame)
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
            clickMenuEnabled: store.behavior.clickMenu,
            includeResize: true
        )
    }

    private func fitBubblePanel(for store: AppStore, visibleFrame: CGRect) {
        guard let bubblePanel else { return }
        guard shouldShowBubble(for: store) else {
            (bubblePanel as? BubbleOverlayPanel)?.stopPointerTracking()
            bubblePanel.orderOut(nil)
            return
        }

        let bubbleContents = store.overlayBubbleContents
        let targetFrame = OverlayGeometry.bubblePanelScreenFrame(
            scale: store.overlayScale,
            petScreenCenter: store.overlayPetScreenCenter,
            visibleFrame: visibleFrame,
            contents: bubbleContents
        )
        if bubblePanel.frame != targetFrame {
            bubblePanel.setFrame(targetFrame, display: true, animate: false)
        }
        if panel?.isVisible == true {
            bubblePanel.orderFront(nil)
            (bubblePanel as? BubbleOverlayPanel)?.startPointerTracking()
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

private final class BubbleOverlayPanel: NSPanel {
    weak var overlayStore: AppStore?
    private let pointerMonitor = OverlayPointerEventMonitor()

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override var canBecomeKey: Bool { false }
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
        guard overlayStore?.behavior.mousePassthrough ?? true else {
            setIgnoresMouseEventsIfNeeded(false)
            return
        }
        setIgnoresMouseEventsIfNeeded(!shouldHandleMouse(screenPoint: NSEvent.mouseLocation))
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
        let topLeftPoint = CGPoint(x: location.x, y: frame.height - location.y)
        let contents = overlayStore.overlayBubbleContents
        let rects = bubbleRects()

        for (content, rect) in zip(contents, rects) where rect.contains(topLeftPoint) {
            let localPoint = CGPoint(x: topLeftPoint.x - rect.minX, y: topLeftPoint.y - rect.minY)
            let topLeftCloseRect = CGRect(x: 0, y: 0, width: 34, height: 34)
            let topRightCloseRect = CGRect(x: rect.width - 36, y: 0, width: 36, height: 34)
            let replyRect = CGRect(x: rect.width - 64, y: rect.height - 34, width: 64, height: 34)

            if topLeftCloseRect.contains(localPoint) || topRightCloseRect.contains(localPoint) {
                overlayStore.dismissOverlayBubble(eventID: content.id)
                return true
            }

            if replyRect.contains(localPoint) {
                overlayStore.presentMainWindow()
                return true
            }
        }

        return false
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
        overlayStore?.setOverlayPointerNearPet(false)
        setIgnoresMouseEventsIfNeeded(false)
    }

    func refreshPointerPassthrough() {
        guard pointerMonitor.isRunning else { return }
        guard overlayStore?.behavior.mousePassthrough ?? true else {
            overlayStore?.setOverlayPointerNearPet(true)
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
        let mouseLocation = NSEvent.mouseLocation
        if let overlayStore {
            let near = OverlayGeometry.pointerNearPetScreenRect(
                scale: overlayStore.overlayScale,
                petScreenCenter: overlayStore.overlayPetScreenCenter,
                clickMenuEnabled: overlayStore.behavior.clickMenu
            ).contains(mouseLocation)
            overlayStore.setOverlayPointerNearPet(near)
        }
        setIgnoresMouseEventsIfNeeded(!shouldHandleMouse(screenPoint: mouseLocation))
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
                setIgnoresMouseEventsIfNeeded(!shouldHandleMouse(localPoint: event.locationInWindow))
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
            includeResize: true
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
            includeResize: true
        )
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
