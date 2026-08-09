import AppKit
import AgentPetCompanionCore
import Combine
import CoreGraphics
import Foundation
import QuartzCore

struct OverlayDisplayGeometry: Equatable, Sendable {
    var frame: CGRect
    var visibleFrame: CGRect
    var backingScaleFactor: CGFloat
}

/// The target display's presentation cadence. `CGDisplayMode.refreshRate`
/// reflects an explicitly selected 50/60/etc. Hz mode; some built-in and
/// adaptive displays report zero there, so AppKit's advertised maximum is the
/// bounded fallback before the conservative 60 Hz default.
struct OverlayDisplayRefreshCadence: Equatable, Sendable {
    let displayID: String
    let framesPerSecond: Double

    init(displayID: String, framesPerSecond: Double) {
        self.displayID = displayID
        self.framesPerSecond = framesPerSecond.isFinite && framesPerSecond > 0
            ? framesPerSecond
            : 60
    }

    var intervalSeconds: TimeInterval {
        1 / framesPerSecond
    }

    static func resolved(for screen: NSScreen?) -> Self {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        let screenNumber = screen?.deviceDescription[screenNumberKey] as? NSNumber
        let displayID = screenNumber?.stringValue ?? "fallback"
        let directDisplayID = screenNumber.map { CGDirectDisplayID($0.uint32Value) }
        let selectedModeRefreshRate = directDisplayID
            .flatMap(CGDisplayCopyDisplayMode)?
            .refreshRate ?? 0
        let advertisedMaximum = Double(screen?.maximumFramesPerSecond ?? 0)
        let refreshRate = selectedModeRefreshRate > 0
            ? selectedModeRefreshRate
            : (advertisedMaximum > 0 ? advertisedMaximum : 60)
        return Self(displayID: displayID, framesPerSecond: refreshRate)
    }
}

/// Latest-value coalescing state shared by pointer drag and display-width
/// preview. Callers inject monotonic timestamps, which keeps the cadence logic
/// deterministic in tests and lets production own exactly one sleeping task.
struct OverlayDisplayRefreshCoalescer<Value> {
    private var pending: Value?
    private var cadence: OverlayDisplayRefreshCadence?
    private var lastDeliveryTime: TimeInterval?
    private(set) var scheduledDeadline: TimeInterval?

    @discardableResult
    mutating func submit(
        _ value: Value,
        at time: TimeInterval,
        cadence proposedCadence: OverlayDisplayRefreshCadence
    ) -> TimeInterval {
        let now = max(0, time)
        pending = value
        if scheduledDeadline == nil || cadence != proposedCadence {
            let earliest: TimeInterval
            if let lastDeliveryTime {
                earliest = lastDeliveryTime + proposedCadence.intervalSeconds
            } else {
                earliest = now + proposedCadence.intervalSeconds
            }
            scheduledDeadline = max(now, earliest)
        }
        cadence = proposedCadence
        return scheduledDeadline ?? now
    }

    mutating func takePending(deliveredAt time: TimeInterval) -> Value? {
        guard let pending else { return nil }
        self.pending = nil
        scheduledDeadline = nil
        lastDeliveryTime = max(lastDeliveryTime ?? 0, max(0, time))
        return pending
    }

    mutating func cancelPending() {
        pending = nil
        scheduledDeadline = nil
        cadence = nil
    }
}

@MainActor
protocol OverlayDisplayRefreshTickSource: AnyObject {
    var isPaused: Bool { get set }
    func invalidate()
}

@MainActor
private final class OverlayDisplayLinkWeakTarget: NSObject {
    private let onTick: @MainActor () -> Void

    init(onTick: @escaping @MainActor () -> Void) {
        self.onTick = onTick
    }

    @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {
        onTick()
    }
}

@MainActor
private final class OverlayScreenDisplayLinkTickSource:
    OverlayDisplayRefreshTickSource
{
    private let target: OverlayDisplayLinkWeakTarget
    // Source creation, mutation, and teardown are MainActor-owned. The unsafe
    // annotation only lets deinit invalidate AppKit's non-Sendable token.
    nonisolated(unsafe) private let displayLink: CADisplayLink

    init?(screen: NSScreen?, onTick: @escaping @MainActor () -> Void) {
        guard let screen else { return nil }
        let target = OverlayDisplayLinkWeakTarget(onTick: onTick)
        let displayLink = screen.displayLink(
            target: target,
            selector: #selector(OverlayDisplayLinkWeakTarget.displayLinkDidFire(_:))
        )
        self.target = target
        self.displayLink = displayLink
        displayLink.isPaused = true
        displayLink.add(to: .main, forMode: .common)
    }

    var isPaused: Bool {
        get { displayLink.isPaused }
        set { displayLink.isPaused = newValue }
    }

    func invalidate() {
        displayLink.invalidate()
    }

    deinit {
        displayLink.invalidate()
    }
}

/// Tick-driven latest-value delivery for direct manipulation. A real target
/// screen binds an `NSScreen` display link, so adaptive-refresh panels follow
/// actual presentation ticks rather than an assumed maximum FPS. The time
/// coalescer remains only as the no-screen/display-link fallback.
@MainActor
final class OverlayDisplayLinkCoalescer<Value> {
    typealias TickSourceFactory = @MainActor (
        _ screen: NSScreen?,
        _ onTick: @escaping @MainActor () -> Void
    ) -> (any OverlayDisplayRefreshTickSource)?

    private let tickSourceFactory: TickSourceFactory
    private var tickSource: (any OverlayDisplayRefreshTickSource)?
    private var targetDisplayID: String?
    private var pending: Value?
    private var delivery: ((Value) -> Void)?
    private var fallbackCoalescer = OverlayDisplayRefreshCoalescer<Void>()
    private var fallbackTask: Task<Void, Never>?
    private var fallbackTaskDeadline: TimeInterval?
    /// Keeps the tick source armed for a whole gesture. Pausing after every
    /// delivery and re-arming on the next pointer sample can miss the upcoming
    /// vsync, so a steady drag presents on an irregular cadence even though
    /// every sample arrives on time.
    private var sustainsTicks = false

    init(
        tickSourceFactory: @escaping TickSourceFactory = { screen, onTick in
            return OverlayScreenDisplayLinkTickSource(
                screen: screen,
                onTick: onTick
            )
        }
    ) {
        self.tickSourceFactory = tickSourceFactory
    }

    var hasPending: Bool { pending != nil }

    /// Holds the tick source unpaused until `endSustainedDelivery`, so an
    /// active gesture presents on every display tick instead of re-arming a
    /// paused link per pointer sample.
    func beginSustainedDelivery() {
        sustainsTicks = true
        tickSource?.isPaused = false
    }

    func endSustainedDelivery() {
        sustainsTicks = false
        guard pending == nil else { return }
        tickSource?.isPaused = true
    }

    func submit(
        _ value: Value,
        targetDisplayID: String,
        screen: NSScreen?,
        fallbackCadence: OverlayDisplayRefreshCadence,
        deliver: @escaping (Value) -> Void
    ) {
        pending = value
        delivery = deliver
        if self.targetDisplayID != targetDisplayID {
            rebind(targetDisplayID: targetDisplayID, screen: screen)
        }
        if let tickSource {
            tickSource.isPaused = false
            return
        }
        let deadline = fallbackCoalescer.submit(
            (),
            at: ProcessInfo.processInfo.systemUptime,
            cadence: fallbackCadence
        )
        scheduleFallback(at: deadline)
    }

    func flushNow() {
        deliverPending()
    }

    func cancelPending() {
        pending = nil
        delivery = nil
        sustainsTicks = false
        tickSource?.isPaused = true
        fallbackTask?.cancel()
        fallbackTask = nil
        fallbackTaskDeadline = nil
        fallbackCoalescer.cancelPending()
    }

    func invalidate() {
        cancelPending()
        tickSource?.invalidate()
        tickSource = nil
        targetDisplayID = nil
    }

    func receiveDisplayRefreshTick() {
        deliverPending()
    }

    private func rebind(targetDisplayID: String, screen: NSScreen?) {
        tickSource?.invalidate()
        tickSource = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        fallbackTaskDeadline = nil
        fallbackCoalescer.cancelPending()
        self.targetDisplayID = targetDisplayID
        tickSource = tickSourceFactory(screen) { [weak self] in
            self?.receiveDisplayRefreshTick()
        }
    }

    private func deliverPending() {
        guard let pending else {
            tickSource?.isPaused = !sustainsTicks
            return
        }
        let delivery = delivery
        self.pending = nil
        self.delivery = nil
        tickSource?.isPaused = !sustainsTicks
        fallbackTask?.cancel()
        fallbackTask = nil
        fallbackTaskDeadline = nil
        _ = fallbackCoalescer.takePending(
            deliveredAt: ProcessInfo.processInfo.systemUptime
        )
        delivery?(pending)
    }

    private func scheduleFallback(at deadline: TimeInterval) {
        if let fallbackTaskDeadline,
           abs(fallbackTaskDeadline - deadline) < 0.000_001,
           fallbackTask != nil {
            return
        }
        fallbackTask?.cancel()
        fallbackTaskDeadline = deadline
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        fallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.fallbackTask = nil
            self.fallbackTaskDeadline = nil
            self.deliverPending()
        }
    }
}

struct OverlayPetVisualEnvelope: Equatable, Sendable {
    var canvasSize: CGSize
    var visibleBounds: CGRect
}

/// A one-bit-per-pixel interaction mask extracted while a pet frame is
/// decoded. Rows are stored in the same top-to-bottom order as the source
/// `CGImage`; callers query it with bottom-left image coordinates so the
/// conversion to the Metal renderer's coordinate system stays explicit.
struct OverlayPetAlphaMask: Equatable, Sendable {
    static let interactionAlphaThreshold: UInt8 = 2

    let pixelWidth: Int
    let pixelHeight: Int
    private let opaqueBits: [UInt8]

    var storageByteCount: Int { opaqueBits.count }

    init?(
        pixelWidth: Int,
        pixelHeight: Int,
        opaqueBits: [UInt8]
    ) {
        guard let requiredByteCount = Self.requiredByteCount(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        ), opaqueBits.count == requiredByteCount else {
            return nil
        }
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.opaqueBits = opaqueBits
    }

    /// Test/support initializer for top-to-bottom, one-byte alpha samples.
    init?(
        pixelWidth: Int,
        pixelHeight: Int,
        alphaValuesTopToBottom: [UInt8],
        alphaThreshold: UInt8 = interactionAlphaThreshold
    ) {
        guard
            let pixelCount = Self.pixelCount(pixelWidth: pixelWidth, pixelHeight: pixelHeight),
            alphaValuesTopToBottom.count == pixelCount,
            let byteCount = Self.requiredByteCount(
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        else {
            return nil
        }
        var bits = [UInt8](repeating: 0, count: byteCount)
        for index in 0..<pixelCount where alphaValuesTopToBottom[index] > alphaThreshold {
            bits[index >> 3] |= UInt8(1 << (index & 7))
        }
        self.init(pixelWidth: pixelWidth, pixelHeight: pixelHeight, opaqueBits: bits)
    }

    func containsOpaquePixel(atBottomLeftPoint point: CGPoint) -> Bool {
        guard point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0,
              point.x < CGFloat(pixelWidth), point.y < CGFloat(pixelHeight) else {
            return false
        }
        let x = Int(point.x.rounded(.down))
        let bottomRow = Int(point.y.rounded(.down))
        let topRow = pixelHeight - 1 - bottomRow
        let index = topRow * pixelWidth + x
        return opaqueBits[index >> 3] & UInt8(1 << (index & 7)) != 0
    }

    static func requiredByteCount(pixelWidth: Int, pixelHeight: Int) -> Int? {
        guard let pixels = pixelCount(pixelWidth: pixelWidth, pixelHeight: pixelHeight) else {
            return nil
        }
        let (adjusted, overflow) = pixels.addingReportingOverflow(7)
        return overflow ? nil : adjusted / 8
    }

    private static func pixelCount(pixelWidth: Int, pixelHeight: Int) -> Int? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let (count, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        return overflow ? nil : count
    }
}

/// Describes the exact decoded frame currently presented by the Metal view.
/// `frameID` lets the renderer and AppStore coalesce repeated display-link
/// draws without comparing the mask payload for every authored frame.
struct OverlayPetFrameHitTest: Equatable, Sendable {
    let frameID: UUID
    let canvasSize: CGSize
    let alphaMask: OverlayPetAlphaMask

    init(
        frameID: UUID = UUID(),
        canvasSize: CGSize,
        alphaMask: OverlayPetAlphaMask
    ) {
        self.frameID = frameID
        self.canvasSize = canvasSize
        self.alphaMask = alphaMask
    }
}

enum OverlayPetAnimationIdentity {
    static func stateEntryID(for state: ActiveAgentState?) -> String {
        guard let state else { return "idle" }
        if let projectedID = nonEmpty(state.overlayDisplay?.stateEntryID) {
            return projectedID
        }
        let event = state.event
        switch event.eventType {
        case .start:
            return "idle"
        case .thinking, .plan:
            let activation = nonEmpty(state.sessionActivatedAt)
                ?? event.id
            return scopedEntryID(
                event: event,
                sessionID: state.sessionID ?? event.sessionID,
                marker: activation,
                reaction: "thinking"
            )
        case .done:
            let completion = nonEmpty(state.sessionActivatedAt)
                ?? event.id
            return scopedEntryID(
                event: event,
                sessionID: state.sessionID ?? event.sessionID,
                marker: completion,
                reaction: "done"
            )
        case .tool, .waiting, .failed:
            // PetCore owns the projected identity, including the tool activity
            // run that lets genuinely new tool work replay its entry burst. A
            // single event carries no run history, so this compatibility
            // fallback keeps one stable identity per reaction.
            return event.eventType.rawValue
        }
    }

    private static func scopedEntryID(
        event: AgentEvent,
        sessionID: String?,
        marker: String,
        reaction: String
    ) -> String {
        [
            reaction,
            event.source.rawValue,
            nonEmpty(sessionID),
            marker
        ]
        .compactMap { $0 }
        .joined(separator: ":")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

}

enum OverlayControlVisibility {
    static let hoverShowDelay = Duration.zero
    static let hoverHideDelay = Duration.milliseconds(300)

    static func isVisible(
        pointerNearPet: Bool,
        petDragInProgress: Bool,
        keyboardFocusActive: Bool = false
    ) -> Bool {
        pointerNearPet || petDragInProgress || keyboardFocusActive
    }

    static func transitionDelay(showing: Bool, forced: Bool) -> Duration {
        forced ? .zero : (showing ? hoverShowDelay : hoverHideDelay)
    }
}

/// Motion values shared by SwiftUI content and the AppKit overlay panels.
enum OverlayMotion {
    static let controlFadeDuration: TimeInterval = 0.14
    static let controlFadeDelay = Duration.milliseconds(140)
    static let bubbleLayoutDuration: TimeInterval = 0.16
    static let bubbleLayoutDelay = Duration.milliseconds(160)
    static let reducedMotionCrossfadeDuration: TimeInterval = 0.16
    static let reducedMotionCrossfadeDelay = Duration.milliseconds(160)
    static let reducedMotionCrossfadeHalfDelay = Duration.milliseconds(80)
}

/// One presentation state coordinates every transient overlay control. Pointer
/// hover begins the visual fade immediately, while pointer exit is delayed to
/// avoid flicker between the pet and its controls. Keyboard focus and an active
/// pet drag remain immediate.
@MainActor
final class OverlayControlPresentationState: ObservableObject {
    typealias TransitionSleeper = @MainActor @Sendable (Duration) async throws -> Void

    enum Region: Hashable {
        case pet
        case bubble
        case menu
    }

    @Published private(set) var isVisible = false
    @Published private(set) var keyboardNavigationActive = false
    var visibilityDidChange: (() -> Void)?

    private var hoveredRegions: Set<Region> = []
    private var focusedRegions: Set<Region> = []
    private var activeRegions: Set<Region> = []
    private var transitionTask: Task<Void, Never>?
    private let transitionSleeper: TransitionSleeper

    init(
        transitionSleeper: @escaping TransitionSleeper = { delay in
            try await Task.sleep(for: delay)
        }
    ) {
        self.transitionSleeper = transitionSleeper
    }

    func setHovered(_ region: Region, _ hovered: Bool) {
        update(region, enabled: hovered, in: &hoveredRegions)
        scheduleVisibilityUpdate()
    }

    func setFocused(_ region: Region, _ focused: Bool) {
        update(region, enabled: focused, in: &focusedRegions)
        let nextKeyboardNavigationActive = !focusedRegions.isEmpty
        if keyboardNavigationActive != nextKeyboardNavigationActive {
            keyboardNavigationActive = nextKeyboardNavigationActive
        }
        scheduleVisibilityUpdate()
    }

    func setActive(_ region: Region, _ active: Bool) {
        update(region, enabled: active, in: &activeRegions)
        scheduleVisibilityUpdate()
    }

    func reset() {
        transitionTask?.cancel()
        transitionTask = nil
        hoveredRegions.removeAll()
        focusedRegions.removeAll()
        activeRegions.removeAll()
        keyboardNavigationActive = false
        setVisible(false)
    }

    private func update(
        _ region: Region,
        enabled: Bool,
        in regions: inout Set<Region>
    ) {
        if enabled {
            regions.insert(region)
        } else {
            regions.remove(region)
        }
    }

    private func scheduleVisibilityUpdate() {
        transitionTask?.cancel()
        let shouldShow = !hoveredRegions.isEmpty
            || !focusedRegions.isEmpty
            || !activeRegions.isEmpty
        let forced = !focusedRegions.isEmpty || !activeRegions.isEmpty
        guard shouldShow != isVisible else { return }
        let delay = OverlayControlVisibility.transitionDelay(
            showing: shouldShow,
            forced: forced
        )
        if delay == .zero {
            setVisible(shouldShow)
            return
        }
        let transitionSleeper = transitionSleeper
        transitionTask = Task { @MainActor [weak self] in
            do {
                try await transitionSleeper(delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            let latestShouldShow = !self.hoveredRegions.isEmpty
                || !self.focusedRegions.isEmpty
                || !self.activeRegions.isEmpty
            guard latestShouldShow == shouldShow else { return }
            self.setVisible(shouldShow)
        }
    }

    private func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        visibilityDidChange?()
    }
}

/// Keeps high-frequency display-size preview out of `AppStore`. Only the pet
/// canvas observes this state, so slider movement does not invalidate the
/// control center, bubbles, or unrelated overlay content.
@MainActor
final class OverlayInteractionPresentationState: ObservableObject {
    private struct DisplayWidthPresentation: Equatable {
        var displayWidthPt: CGFloat
        var petLocalCenter: CGPoint
    }

    @Published private var displayWidthPresentation: DisplayWidthPresentation?
    @Published private(set) var petInteraction: OverlayPetInteractionPresentation?
    @Published private(set) var pressFeedbackActive = false
    private var dragInteractionID: UUID?
    private var lastDragCenter: CGPoint?

    func resolvedDisplayWidthPt(fallback: CGFloat) -> CGFloat {
        displayWidthPresentation?.displayWidthPt ?? fallback
    }

    func resolvedPetLocalCenter(fallback: CGPoint) -> CGPoint {
        displayWidthPresentation?.petLocalCenter ?? fallback
    }

    func present(displayWidthPt: CGFloat, petLocalCenter: CGPoint) {
        let next = DisplayWidthPresentation(
            displayWidthPt: displayWidthPt,
            petLocalCenter: petLocalCenter
        )
        guard displayWidthPresentation != next else { return }
        displayWidthPresentation = next
    }

    func clearDisplayWidthPreview() {
        guard displayWidthPresentation != nil else { return }
        displayWidthPresentation = nil
    }

    func acknowledge(reduceMotion: Bool) {
        guard !reduceMotion, dragInteractionID == nil else { return }
        let interactionID = UUID()
        petInteraction = OverlayPetInteractionPresentation(
            stateName: "acknowledge",
            entryID: "interaction:\(interactionID.uuidString):acknowledge"
        )
    }

    func beginPressFeedback(enabled: Bool, reduceMotion: Bool) {
        guard enabled, !reduceMotion, dragInteractionID == nil else { return }
        pressFeedbackActive = true
    }

    func beginDrag(interactionID: UUID, center: CGPoint) {
        dragInteractionID = interactionID
        lastDragCenter = center
        petInteraction = nil
    }

    func updateDrag(interactionID: UUID, center: CGPoint) {
        guard dragInteractionID == interactionID else { return }
        pressFeedbackActive = false
        let priorCenter = lastDragCenter ?? center
        lastDragCenter = center
        let horizontalDelta = center.x - priorCenter.x
        guard abs(horizontalDelta) >= OverlayPetInteractionPolicy.directionThresholdPt else {
            return
        }
        let stateName = horizontalDelta < 0 ? "drag_left" : "drag_right"
        guard petInteraction?.stateName != stateName else { return }
        petInteraction = OverlayPetInteractionPresentation(
            stateName: stateName,
            entryID: "interaction:\(interactionID.uuidString):\(stateName)"
        )
    }

    func endDrag(interactionID: UUID?) {
        if let interactionID, dragInteractionID != interactionID { return }
        dragInteractionID = nil
        lastDragCenter = nil
        pressFeedbackActive = false
        if petInteraction?.stateName == "drag_left"
            || petInteraction?.stateName == "drag_right"
        {
            petInteraction = nil
        }
    }

    func complete(entryID: String) {
        guard petInteraction?.entryID == entryID,
              petInteraction?.stateName == "acknowledge"
        else { return }
        petInteraction = nil
    }
}

struct OverlayPetInteractionPresentation: Equatable, Sendable {
    var stateName: String
    var entryID: String
}

enum OverlayPetInteractionPolicy {
    static let directionThresholdPt: CGFloat = 0.5
    static let pressFeedbackDurationSeconds = 0.16
}

enum OverlayPointerMaskState: Equatable, Sendable {
    case missing
    case valid
    case stale
}

struct OverlayPointerOwnershipInput: Equatable, Sendable {
    var overlayVisible: Bool
    var primaryButtonDown: Bool
    var activeInteractionID: UUID?
    var maskState: OverlayPointerMaskState
    var validMaskPixelIsOpaque: Bool
    var pointerInBubble: Bool
    var pointerInMenu: Bool
    var pointerInGeometricPetRegion: Bool
}

enum OverlayPointerOwnership: Equatable, Sendable {
    case passthrough
    case pet
    case auxiliarySurface
    case activeLease(UUID)

    var isOwnedByOverlay: Bool {
        self != .passthrough
    }
}

/// The only policy that decides whether the overlay owns a pointer location.
/// AppKit event routing remains a defensive delivery mechanism; it does not
/// redefine mask fallback or active-gesture ownership.
enum OverlayPointerOwnershipPolicy {
    static func resolve(
        _ input: OverlayPointerOwnershipInput
    ) -> OverlayPointerOwnership {
        guard input.overlayVisible else { return .passthrough }
        if let interactionID = input.activeInteractionID {
            return .activeLease(interactionID)
        }
        if input.pointerInBubble || input.pointerInMenu {
            return .auxiliarySurface
        }
        guard input.pointerInGeometricPetRegion else {
            return .passthrough
        }
        switch input.maskState {
        case .valid:
            return input.validMaskPixelIsOpaque ? .pet : .passthrough
        case .missing, .stale:
            return .pet
        }
    }
}

enum OverlayPetPointerGesture {
    static let dragThreshold: CGFloat = 4

    static func exceedsDragThreshold(from start: CGPoint, to current: CGPoint) -> Bool {
        hypot(current.x - start.x, current.y - start.y) >= dragThreshold
    }

    /// AppKit reports a double-click as click counts one and two. Performing
    /// the primary action only for the first release preserves responsive
    /// single-click behavior without toggling the bubble back on the second.
    static func shouldPerformPrimaryClick(clickCount: Int, didDrag: Bool) -> Bool {
        !didDrag && clickCount == 1
    }
}

/// Converts a pointer sample out of CoreGraphics' global event space into the
/// AppKit screen space the drag anchor uses. A drag translates the host window
/// on every display tick, so a sample derived from the window's own coordinate
/// system silently subtracts a move it never observed; taking the event's
/// absolute location instead keeps the grab point fixed under the pointer no
/// matter how far or how fast the composition has moved.
enum OverlayPointerCoordinateSpace {
    static func screenPoint(
        forGlobalEventLocation location: CGPoint,
        zeroOriginScreenFrame: CGRect
    ) -> CGPoint {
        CGPoint(
            x: location.x,
            y: zeroOriginScreenFrame.maxY - location.y
        )
    }
}

enum OverlayPointerGesturePhase: Equatable, Sendable {
    case idle
    case pressed
    case dragging
    case finalized
}

struct OverlayDragSession: Equatable, Sendable {
    let interactionID: UUID
    let startPointerScreen: CGPoint
    let startAnchorScreen: CGPoint
    var latestPointerScreen: CGPoint
    let startDisplayID: String
    var hasCrossedThreshold: Bool
    private(set) var phase: OverlayPointerGesturePhase

    init(
        interactionID: UUID = UUID(),
        startPointerScreen: CGPoint,
        startAnchorScreen: CGPoint,
        startDisplayID: String
    ) {
        self.interactionID = interactionID
        self.startPointerScreen = startPointerScreen
        self.startAnchorScreen = startAnchorScreen
        latestPointerScreen = startPointerScreen
        self.startDisplayID = startDisplayID
        hasCrossedThreshold = false
        phase = .pressed
    }

    var proposedAnchorScreen: CGPoint {
        CGPoint(
            x: startAnchorScreen.x
                + latestPointerScreen.x
                - startPointerScreen.x,
            y: startAnchorScreen.y
                + latestPointerScreen.y
                - startPointerScreen.y
        )
    }

    mutating func updatePointer(_ point: CGPoint) {
        guard phase != .finalized else { return }
        latestPointerScreen = point
        if !hasCrossedThreshold {
            hasCrossedThreshold = OverlayPetPointerGesture.exceedsDragThreshold(
                from: startPointerScreen,
                to: point
            )
            if hasCrossedThreshold {
                phase = .dragging
            }
        }
    }

    mutating func compareAndFinalize(interactionID: UUID) -> Bool {
        guard self.interactionID == interactionID,
              phase != .finalized else { return false }
        phase = .finalized
        return true
    }
}

struct OverlayDragDisplay: Equatable, Sendable {
    let id: String
    let frame: CGRect
    let visibleFrame: CGRect
}

/// Display geometry and presentation cadence captured once per gesture rather
/// than per pointer sample. Rebuilding the screen list and asking CoreGraphics
/// for the selected display mode on every event costs a window-server round
/// trip inside the pointer handler, which is exactly the per-event main-thread
/// work that makes a fast drag stutter. The desktop arrangement only changes
/// through a screen-parameter notification, so a gesture-scoped snapshot stays
/// authoritative for the whole drag.
struct OverlayDragDisplayCatalog: Equatable, Sendable {
    let displays: [OverlayDragDisplay]
    let fallbackCadence: OverlayDisplayRefreshCadence
    private let cadences: [String: OverlayDisplayRefreshCadence]

    init(
        displays: [OverlayDragDisplay],
        cadences: [String: OverlayDisplayRefreshCadence],
        fallbackCadence: OverlayDisplayRefreshCadence
    ) {
        self.displays = displays
        self.cadences = cadences
        self.fallbackCadence = fallbackCadence
    }

    func cadence(for displayID: String?) -> OverlayDisplayRefreshCadence {
        guard let displayID, let cadence = cadences[displayID] else {
            return fallbackCadence
        }
        return cadence
    }
}

/// Selects the drag display from injected geometry so crossing a display edge
/// does not replace the absolute pointer anchor with window-relative deltas.
enum OverlayDragScreenResolver {
    static func resolve(
        pointer: CGPoint,
        proposedPetCenter: CGPoint,
        displays: [OverlayDragDisplay],
        fallbackDisplayID: String?
    ) -> OverlayDragDisplay? {
        displays.first { $0.frame.contains(pointer) }
            ?? displays.first { $0.frame.contains(proposedPetCenter) }
            ?? fallbackDisplayID.flatMap { fallbackID in
                displays.first { $0.id == fallbackID }
            }
            ?? displays.first
    }
}

enum OverlayInteractionWindowRole: Equatable, Sendable {
    case parentPetPanel
    case bubbleChildPanel
    case menuChildPanel
}

struct OverlayInteractionWindowMove: Equatable, Sendable {
    let role: OverlayInteractionWindowRole
    let frame: CGRect
}

enum OverlayAuxiliaryPanelAttachmentPlan: Equatable, Sendable {
    case none
    case attach
    case reparent
    case rejectCycle
}

enum OverlayAuxiliaryPanelAttachmentPolicy {
    static func plan(
        currentParentMatchesTarget: Bool,
        hasCurrentParent: Bool,
        wouldCreateCycle: Bool
    ) -> OverlayAuxiliaryPanelAttachmentPlan {
        if wouldCreateCycle { return .rejectCycle }
        if currentParentMatchesTarget { return .none }
        return hasCurrentParent ? .reparent : .attach
    }
}

enum OverlayCompositionLayoutMode: Equatable, Sendable {
    case resting
    case directManipulation
}

/// The bubble attaches to the pet's top or bottom edge only. Placing it beside
/// the pet would break the single vertical gap the composition is built on, so
/// there is deliberately no left/right case to fall back to.
enum OverlayBubbleAnchorDirection: String, CaseIterable, Equatable, Sendable {
    case above
    case below

    var opposite: Self {
        self == .above ? .below : .above
    }
}

/// The complete bubble attachment decision. Both the side the bubble hangs
/// from and the edge it aligns to are sticky: each is re-decided only when the
/// current choice no longer fits the safe area. Deciding the horizontal edge
/// from the raw screen midline instead would flip the bubble by its own width
/// the moment a drag crosses the middle of the display.
struct OverlayBubbleAnchor: Equatable, Sendable {
    let direction: OverlayBubbleAnchorDirection
    let alignsLeft: Bool

    init(direction: OverlayBubbleAnchorDirection, alignsLeft: Bool) {
        self.direction = direction
        self.alignsLeft = alignsLeft
    }
}

struct OverlayBubblePanelLayout: Equatable, Sendable {
    let frame: CGRect
    let anchor: OverlayBubbleAnchor

    var direction: OverlayBubbleAnchorDirection { anchor.direction }
}

struct OverlayAuxiliaryRelativeFrameSnapshot: Equatable, Sendable {
    let bubbleFrame: CGRect?
    let menuFrame: CGRect?

    static func capture(
        parentFrame: CGRect,
        bubbleFrame: CGRect?,
        menuFrame: CGRect?
    ) -> Self {
        Self(
            bubbleFrame: bubbleFrame.map {
                $0.offsetBy(dx: -parentFrame.minX, dy: -parentFrame.minY)
            },
            menuFrame: menuFrame.map {
                $0.offsetBy(dx: -parentFrame.minX, dy: -parentFrame.minY)
            }
        )
    }
}

/// The pet's position inside its own panel, captured once when a gesture
/// begins. Every presented frame then derives the panel origin from the
/// presented pet center alone, so the composition can never accumulate a
/// per-frame error and no other window move can shift the grab point.
struct OverlayDirectManipulationAnchor: Equatable, Sendable {
    let panelOriginOffset: CGVector
    let panelSize: CGSize

    init(panelFrame: CGRect, petScreenCenter: CGPoint) {
        panelOriginOffset = CGVector(
            dx: panelFrame.minX - petScreenCenter.x,
            dy: panelFrame.minY - petScreenCenter.y
        )
        panelSize = panelFrame.size
    }

    func panelFrame(forPetScreenCenter center: CGPoint) -> CGRect {
        CGRect(
            origin: CGPoint(
                x: center.x + panelOriginOffset.dx,
                y: center.y + panelOriginOffset.dy
            ),
            size: panelSize
        )
    }
}

/// Auxiliary geometry that stays fixed for a whole gesture. Bubble content is
/// not re-measured while the pointer moves, so the drag path re-anchors the
/// size captured when the gesture began and never re-runs text layout per
/// display tick.
struct OverlayDirectManipulationAuxiliaryInput: Equatable, Sendable {
    let displayWidthPt: CGFloat
    let visibleFrame: CGRect
    let petVisualEnvelope: OverlayPetVisualEnvelope?
    let bubbleSize: CGSize?
    let previousBubbleAnchor: OverlayBubbleAnchor?
    let menuVisible: Bool

    init(
        displayWidthPt: CGFloat,
        visibleFrame: CGRect,
        petVisualEnvelope: OverlayPetVisualEnvelope?,
        bubbleSize: CGSize?,
        previousBubbleAnchor: OverlayBubbleAnchor?,
        menuVisible: Bool
    ) {
        self.displayWidthPt = displayWidthPt
        self.visibleFrame = visibleFrame
        self.petVisualEnvelope = petVisualEnvelope
        self.bubbleSize = bubbleSize
        self.previousBubbleAnchor = previousBubbleAnchor
        self.menuVisible = menuVisible
    }
}

struct OverlayDirectManipulationPlan: Equatable, Sendable {
    let moves: [OverlayInteractionWindowMove]
    let bubbleAnchor: OverlayBubbleAnchor?
}

/// The display-link delivery path moves the whole composition, not just the
/// pet. Every frame in the plan is an absolute position derived from the
/// presented pet center and the anchor captured when the gesture began, so a
/// dropped, late, or externally disturbed frame cannot leave a residue that the
/// next frame builds on. Auxiliary panels are AppKit child windows, so a parent
/// translation already carries them; these moves additionally re-anchor them,
/// which is what keeps a bubble attached to the pet while the pet crosses a
/// screen edge instead of deferring one hard correction to the release. Frames
/// stay unrounded during a gesture so a 1 px integral snap cannot shimmer
/// against the smoothly translated parent.
enum OverlayDirectManipulationMovePlan {
    static func moves(
        anchor: OverlayDirectManipulationAnchor,
        parentFrame: CGRect,
        presentedPetCenter: CGPoint
    ) -> [OverlayInteractionWindowMove] {
        plan(
            anchor: anchor,
            parentFrame: parentFrame,
            presentedPetCenter: presentedPetCenter,
            auxiliary: nil
        ).moves
    }

    static func plan(
        anchor: OverlayDirectManipulationAnchor,
        parentFrame: CGRect,
        presentedPetCenter: CGPoint,
        auxiliary: OverlayDirectManipulationAuxiliaryInput?
    ) -> OverlayDirectManipulationPlan {
        var moves: [OverlayInteractionWindowMove] = []
        let targetFrame = anchor.panelFrame(forPetScreenCenter: presentedPetCenter)
        if targetFrame != parentFrame {
            moves.append(OverlayInteractionWindowMove(
                role: .parentPetPanel,
                frame: targetFrame
            ))
        }

        guard let auxiliary else {
            return OverlayDirectManipulationPlan(moves: moves, bubbleAnchor: nil)
        }

        var bubbleAnchor: OverlayBubbleAnchor?
        if let bubbleSize = auxiliary.bubbleSize,
           bubbleSize.width > 0,
           bubbleSize.height > 0
        {
            let placement = OverlayGeometry.bubblePlacement(
                bubbleSize: bubbleSize,
                displayWidthPt: auxiliary.displayWidthPt,
                petScreenCenter: presentedPetCenter,
                screenFrame: auxiliary.visibleFrame,
                petVisualEnvelope: auxiliary.petVisualEnvelope,
                previousAnchor: auxiliary.previousBubbleAnchor
            )
            bubbleAnchor = placement.anchor
            moves.append(OverlayInteractionWindowMove(
                role: .bubbleChildPanel,
                frame: OverlayGeometry.rect(
                    center: placement.center,
                    size: bubbleSize
                )
            ))
        }

        if auxiliary.menuVisible {
            moves.append(OverlayInteractionWindowMove(
                role: .menuChildPanel,
                frame: OverlayGeometry.rect(
                    center: OverlayGeometry.menuScreenCenter(
                        petScreenCenter: presentedPetCenter,
                        displayWidthPt: auxiliary.displayWidthPt,
                        petVisualEnvelope: auxiliary.petVisualEnvelope
                    ),
                    size: OverlayGeometry.menuHitSize
                )
            ))
        }

        return OverlayDirectManipulationPlan(
            moves: moves,
            bubbleAnchor: bubbleAnchor
        )
    }
}

/// Pure geometry for direct manipulation. Dragging has no rubber band,
/// projection, velocity handoff, settling, momentum, or bounce.
enum OverlayPetDragGeometry {
    static func clampedCenter(
        _ proposedCenter: CGPoint,
        displayWidthPt: CGFloat,
        visibleFrame: CGRect,
        clickMenuEnabled: Bool = true,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> CGPoint {
        OverlayGeometry.clampedPetScreenCenter(
            proposedCenter,
            displayWidthPt: displayWidthPt,
            visibleFrame: visibleFrame,
            clickMenuEnabled: clickMenuEnabled,
            petVisualEnvelope: petVisualEnvelope
        )
    }
}

enum OverlayPresentedAgentState {
    /// Current PetCore snapshots use `activeSessions` as the bounded liveness
    /// projection for both bubbles and pet reactions. `AppStore` already
    /// synthesizes that array from `canonicalState` when decoding an older
    /// compatible snapshot, so a current empty array must not fall back to a
    /// canonical session that PetCore deliberately omitted as expired.
    static func resolve(
        canonicalState _: ActiveAgentState?,
        activeSessions: [ActiveAgentState],
        dismissedSessionIDs: Set<String>
    ) -> ActiveAgentState? {
        activeSessions.first(where: {
            !isDismissed($0, dismissedSessionIDs: dismissedSessionIDs)
        })
    }

    static func newlyActivatedDismissalIDs(
        activeSessions: [ActiveAgentState],
        lastReopenIDBySession: [String: String]
    ) -> Set<String> {
        Set(activeSessions.compactMap { state -> String? in
            let stableID = OverlaySessionContent.stableID(
                source: state.source,
                sessionID: state.sessionID ?? state.event.sessionID,
                anonymousSessionAlias: state.anonymousSessionAlias,
                fallbackEventID: state.event.id
            )
            guard lastReopenIDBySession[stableID] != OverlaySessionContent.reopenID(for: state)
            else {
                return nil
            }
            return stableID
        })
    }

    private static func isDismissed(
        _ state: ActiveAgentState,
        dismissedSessionIDs: Set<String>
    ) -> Bool {
        dismissedSessionIDs.contains(OverlaySessionContent.stableID(
            source: state.source,
            sessionID: state.sessionID ?? state.event.sessionID,
            anonymousSessionAlias: state.anonymousSessionAlias,
            fallbackEventID: state.event.id
        ))
    }
}

enum OverlayGeometry {
    static let minimumDisplayWidthPt = CGFloat(
        OverlayPlacement.minimumDisplayWidthPt
    )
    static let maximumDisplayWidthPt = CGFloat(
        OverlayPlacement.maximumDisplayWidthPt
    )
    static let defaultDisplayWidthPt = CGFloat(
        OverlayPlacement.defaultDisplayWidthPt
    )
    static let displayAspectHeightRatio: CGFloat = 208 / 192
    static let bubbleWidth: CGFloat = 344
    static let bubbleAdaptiveMinimumWidth: CGFloat = 304
    static let bubbleAdaptiveMaximumWidth: CGFloat = 360
    static let bubbleMinimumHeight: CGFloat = 70
    static let bubbleMaximumHeight: CGFloat = 680
    static let bubbleGap: CGFloat = 3
    static let bubbleMinimumWidth: CGFloat = 304
    static let bubbleStackSpacing: CGFloat = 4
    /// Keeps the multi-session surface visibly lens-like without turning the
    /// variable-height product card into a copied activity-pill capsule.
    static let bubbleCornerRadius: CGFloat = 20
    static let bubbleLeadingPadding: CGFloat = 8
    static let bubbleTrailingPadding: CGFloat = 8
    static let bubbleVerticalPadding: CGFloat = 7
    static func bubbleGroupHeaderHeight(
        fontScale: BubbleFontScale = .standard
    ) -> CGFloat {
        max(
            OverlayBubbleTypography.scaledControlMetric(17, scale: fontScale),
            ceil(lineHeight(for: OverlayBubbleTypography.measurementFont(
                .caption1,
                scale: fontScale
            ))) + 2
        )
    }
    static let bubbleGroupHeaderSpacing: CGFloat = 4
    static func bubbleGroupToggleWidth(
        fontScale: BubbleFontScale = .standard
    ) -> CGFloat {
        OverlayBubbleTypography.scaledControlMetric(44, scale: fontScale)
    }
    static let bubbleSessionHorizontalPadding: CGFloat = 8
    static let bubbleSessionVerticalPadding: CGFloat = 5
    static let bubbleSessionTitleSpacing: CGFloat = 2
    static let bubbleDetailLineLimit = 2
    static let bubbleStandaloneSummaryLineLimit = 2
    static let bubbleStandaloneMetadataSpacing: CGFloat = 3
    static func bubbleDetailTextHeight(
        fontScale: BubbleFontScale = .standard
    ) -> CGFloat {
        ceil(
            lineHeight(for: OverlayBubbleTypography.measurementFont(
                .caption1,
                scale: fontScale
            )) * CGFloat(bubbleDetailLineLimit)
        )
    }
    static func bubbleDetailedHeaderHeight(
        fontScale: BubbleFontScale = .standard
    ) -> CGFloat {
        max(
            ceil(lineHeight(for: OverlayBubbleTypography.measurementFont(
                .callout,
                scale: fontScale
            ))),
            ceil(lineHeight(for: OverlayBubbleTypography.measurementFont(
                .caption2,
                scale: fontScale
            ))) + 2
        )
    }
    static func bubbleStandaloneSummaryTextHeight(
        fontScale: BubbleFontScale = .standard
    ) -> CGFloat {
        ceil(
            lineHeight(for: OverlayBubbleTypography.measurementFont(
                .callout,
                scale: fontScale
            )) * CGFloat(bubbleStandaloneSummaryLineLimit)
        )
    }
    static let bubbleSessionDividerHeight: CGFloat = 1
    static let bubbleHeaderAvatarWidth: CGFloat = 14
    static func bubbleHeaderButtonSize(
        fontScale: BubbleFontScale = .standard
    ) -> CGFloat {
        max(
            OverlayBubbleTypography.scaledControlMetric(15, scale: fontScale),
            bubbleGroupHeaderHeight(fontScale: fontScale) - 2
        )
    }
    static let bubbleHeaderGap: CGFloat = 5
    static let bubbleCollapsedStackLayerCount = 2
    static let bubbleCollapsedStackLayerOffset: CGFloat = 4
    static let bubbleCollapsedStackLayerInset: CGFloat = 5
    static let bubbleStandaloneStackLayerOffset: CGFloat = 10
    static let bubbleStandaloneStackLayerInset: CGFloat = 10
    static let menuVisualSize = CGSize(width: 24, height: 24)
    static let menuHitSize = CGSize(width: 38, height: 38)
    static let controlVisibilitySlop: CGFloat = 4
    private static let petStagePadding: CGFloat = 8
    private static let petShadowRadius: CGFloat = 10
    private static let petShadowYOffset: CGFloat = 6
    private static let panelContentPadding: CGFloat = 2
    private static let petControlTrailingGap: CGFloat = 8
    private static let petMenuToPetGap: CGFloat = 3

    static func clampedPoint(_ base: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(base.x, 44), max(44, size.width - 44)),
            y: min(max(base.y, 44), max(44, size.height - 44))
        )
    }

    static func resolvedBubbleSize(
        in size: CGSize,
        content: OverlayBubbleContent = .measurementPlaceholder,
        fontScale: BubbleFontScale = .standard
    ) -> CGSize {
        let availableWidth = max(96, size.width - 32)
        let maximumWidth = min(bubbleAdaptiveMaximumWidth, availableWidth)
        let width = maximumWidth < bubbleAdaptiveMinimumWidth
            ? maximumWidth
            : min(bubbleWidth, maximumWidth)
        let measuredHeight = measuredBubbleHeight(
            width: width,
            content: content,
            fontScale: fontScale
        )
        let availableHeight = max(44, size.height - 16)
        return CGSize(
            width: width,
            height: min(
                bubbleMaximumHeight,
                availableHeight,
                max(bubbleMinimumHeight, measuredHeight)
            )
        )
    }

    static func resolvedBubbleSizes(
        in size: CGSize,
        contents: [OverlayBubbleContent],
        fontScale: BubbleFontScale = .standard
    ) -> [CGSize] {
        contents.map {
            resolvedBubbleSize(in: size, content: $0, fontScale: fontScale)
        }
    }

    static func resolvedBubbleStackSize(
        in size: CGSize,
        contents: [OverlayBubbleContent],
        fontScale: BubbleFontScale = .standard
    ) -> CGSize {
        let bubbleSizes = resolvedBubbleSizes(
            in: size,
            contents: contents,
            fontScale: fontScale
        )
        guard !bubbleSizes.isEmpty else { return .zero }
        let totalHeight = bubbleSizes.map(\.height).reduce(0, +)
            + CGFloat(max(0, bubbleSizes.count - 1)) * bubbleStackSpacing
        return CGSize(
            width: bubbleSizes.map(\.width).max() ?? 0,
            height: totalHeight
        )
    }

    static func bubbleRects(
        inPanelSize panelSize: CGSize,
        visibleFrameSize: CGSize,
        contents: [OverlayBubbleContent],
        alignLeft: Bool,
        fontScale: BubbleFontScale = .standard
    ) -> [CGRect] {
        let bubbleSizes = resolvedBubbleSizes(
            in: visibleFrameSize,
            contents: contents,
            fontScale: fontScale
        )
        var currentY: CGFloat = 0
        return bubbleSizes.map { size in
            defer { currentY += size.height + bubbleStackSpacing }
            return CGRect(
                x: alignLeft ? 0 : max(0, panelSize.width - size.width),
                y: currentY,
                width: size.width,
                height: size.height
            )
        }
    }

    /// Bubble contents always use top-to-bottom reading order. The first card
    /// is the same priority card shown in the folded foreground, independent
    /// of whether the composition attaches above or below the pet. Keeping one
    /// order also ensures SwiftUI rendering, accessibility, and AppKit hit
    /// routing resolve the same card at every disclosure level.
    static func visuallyOrderedBubbleContents(
        _ contents: [OverlayBubbleContent],
        anchorDirection _: OverlayBubbleAnchorDirection
    ) -> [OverlayBubbleContent] {
        contents
    }

    static func bubbleCloseHitRect(
        in bubbleRect: CGRect,
        fontScale: BubbleFontScale = .standard
    ) -> CGRect {
        let headerHitHeight = bubbleVerticalPadding
            + bubbleGroupHeaderHeight(fontScale: fontScale)
            + bubbleGroupHeaderSpacing
        let headerTrailingControlWidth = bubbleTrailingPadding
            + bubbleHeaderButtonSize(fontScale: fontScale)
            + bubbleHeaderGap
        return CGRect(
            x: bubbleRect.maxX - headerTrailingControlWidth,
            y: bubbleRect.minY,
            width: headerTrailingControlWidth,
            height: min(headerHitHeight, bubbleRect.height)
        )
    }

    static func bubbleGroupToggleHitRect(
        in bubbleRect: CGRect,
        content: OverlayBubbleContent,
        fontScale: BubbleFontScale = .standard
    ) -> CGRect {
        guard content.hasMultipleSessions,
              !content.isStandaloneSessionCard
        else { return .zero }
        let closeRect = bubbleCloseHitRect(in: bubbleRect, fontScale: fontScale)
        let toggleWidth = bubbleGroupToggleWidth(fontScale: fontScale)
        return CGRect(
            x: closeRect.minX - toggleWidth,
            y: bubbleRect.minY,
            width: toggleWidth,
            height: closeRect.height
        )
    }

    static func bubbleSessionRects(
        in bubbleRect: CGRect,
        content: OverlayBubbleContent,
        fontScale: BubbleFontScale = .standard
    ) -> [CGRect] {
        let innerWidth = max(0, bubbleRect.width - bubbleLeadingPadding - bubbleTrailingPadding)
        let rowHeights = bubbleSessionRowHeights(
            bubbleWidth: bubbleRect.width,
            content: content,
            fontScale: fontScale
        )
        var y = bubbleRect.minY + bubbleVerticalPadding
        if !content.isStandaloneSessionCard {
            y += bubbleGroupHeaderHeight(fontScale: fontScale) + bubbleGroupHeaderSpacing
        }
        return rowHeights.map { height in
            defer { y += height + bubbleSessionDividerHeight }
            return CGRect(
                x: bubbleRect.minX + bubbleLeadingPadding,
                y: y,
                width: innerWidth,
                height: height
            )
        }
    }

    static func bubbleSessionRowHeights(
        bubbleWidth: CGFloat,
        content: OverlayBubbleContent,
        fontScale: BubbleFontScale = .standard
    ) -> [CGFloat] {
        content.visibleSessions.map { session in
            measuredSessionRowHeight(
                width: bubbleWidth,
                session: session,
                isStandaloneSessionCard: content.isStandaloneSessionCard,
                fontScale: fontScale
            )
        }
    }

    static func defaultPetScreenCenter(
        in visibleFrame: CGRect,
        displayWidthPt: CGFloat
    ) -> CGPoint {
        let petSize = petVisibleSize(displayWidthPt: displayWidthPt)
        return clampedPetScreenCenter(
            CGPoint(
                x: visibleFrame.maxX - petSize.width * 0.72,
                y: visibleFrame.minY + petSize.height * 0.62
            ),
            displayWidthPt: displayWidthPt,
            visibleFrame: visibleFrame
        )
    }

    static func localPoint(
        forScreenPoint screenPoint: CGPoint,
        panelFrame: CGRect,
        fallbackIn size: CGSize
    ) -> CGPoint {
        guard !panelFrame.isEmpty else {
            return CGPoint(x: size.width * 0.72, y: size.height * 0.64)
        }
        return CGPoint(
            x: screenPoint.x - panelFrame.minX,
            y: panelFrame.maxY - screenPoint.y
        )
    }

    static func screenPoint(forLocalPoint localPoint: CGPoint, panelFrame: CGRect) -> CGPoint {
        CGPoint(
            x: panelFrame.minX + localPoint.x,
            y: panelFrame.maxY - localPoint.y
        )
    }

    static func topLeftPoint(forViewPoint point: CGPoint, in viewHeight: CGFloat, isFlipped: Bool) -> CGPoint {
        CGPoint(
            x: point.x,
            y: isFlipped ? point.y : viewHeight - point.y
        )
    }

    static func clampedPetScreenCenter(
        _ proposedCenter: CGPoint,
        displayWidthPt: CGFloat,
        visibleFrame: CGRect,
        clickMenuEnabled: Bool = true,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> CGPoint {
        guard !visibleFrame.isEmpty else { return proposedCenter }

        let relativeBounds = petMovementScreenBounds(
            displayWidthPt: displayWidthPt,
            petScreenCenter: .zero,
            clickMenuEnabled: clickMenuEnabled,
            petVisualEnvelope: petVisualEnvelope
        )
        let edgeInset: CGFloat = 1
        let minX = visibleFrame.minX - relativeBounds.minX + edgeInset
        let maxX = visibleFrame.maxX - relativeBounds.maxX - edgeInset
        let minY = visibleFrame.minY - relativeBounds.minY + edgeInset
        let maxY = visibleFrame.maxY - relativeBounds.maxY - edgeInset

        return CGPoint(
            x: inwardCanonicalClamp(
                proposedCenter.x,
                lower: minX,
                upper: maxX
            ),
            y: inwardCanonicalClamp(
                proposedCenter.y,
                lower: minY,
                upper: maxY
            )
        )
    }

    /// Movement intentionally permits the pet to enter the Dock reservation at
    /// the bottom or side of a display. The menu-bar strip remains protected so
    /// the pet and its controls cannot become unreachable behind system chrome.
    static func petMovementFrame(screenFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        guard !screenFrame.isEmpty else { return visibleFrame }
        guard !visibleFrame.isEmpty else { return screenFrame }

        let protectedTop = min(screenFrame.maxY, visibleFrame.maxY)
        guard protectedTop > screenFrame.minY else { return screenFrame }
        return CGRect(
            x: screenFrame.minX,
            y: screenFrame.minY,
            width: screenFrame.width,
            height: protectedTop - screenFrame.minY
        )
    }

    static func bubblePosition(
        bubbleSize: CGSize,
        displayWidthPt: CGFloat,
        petCenter: CGPoint,
        panelFrame: CGRect,
        screenFrame: CGRect,
        in size: CGSize
    ) -> CGPoint {
        let petScreenPoint = screenPoint(forLocalPoint: petCenter, panelFrame: panelFrame)
        let screenCenter = bubbleScreenCenter(
            bubbleSize: bubbleSize,
            displayWidthPt: displayWidthPt,
            petScreenCenter: petScreenPoint,
            screenFrame: screenFrame
        )
        return localPoint(forScreenPoint: screenCenter, panelFrame: panelFrame, fallbackIn: size)
    }

    static func bubbleScreenCenter(
        bubbleSize: CGSize,
        displayWidthPt: CGFloat,
        petScreenCenter: CGPoint,
        screenFrame: CGRect,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> CGPoint {
        bubblePlacement(
            bubbleSize: bubbleSize,
            displayWidthPt: displayWidthPt,
            petScreenCenter: petScreenCenter,
            screenFrame: screenFrame,
            petVisualEnvelope: petVisualEnvelope,
            previousAnchor: nil
        ).center
    }

    static func bubblePlacement(
        bubbleSize: CGSize,
        displayWidthPt: CGFloat,
        petScreenCenter: CGPoint,
        screenFrame: CGRect,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil,
        previousAnchor: OverlayBubbleAnchor?
    ) -> (center: CGPoint, anchor: OverlayBubbleAnchor) {
        let petSize = petVisibleSize(displayWidthPt: displayWidthPt)
        let verticalOffsets = petVisualVerticalOffsets(
            displayWidthPt: displayWidthPt,
            envelope: petVisualEnvelope
        )
        let petLeft = petScreenCenter.x - petSize.width / 2
        let petRight = petScreenCenter.x + petSize.width / 2
        let petTop = petScreenCenter.y + verticalOffsets.top
        let petBottom = petScreenCenter.y + verticalOffsets.bottom

        func attachedX(alignsLeft: Bool) -> CGFloat {
            alignsLeft
                ? petLeft + bubbleSize.width / 2
                : petRight - bubbleSize.width / 2
        }
        let midlineAlignsLeft = screenFrame.isEmpty
            ? false
            : petScreenCenter.x < screenFrame.midX
        // The screen midline alone would swap the attached edge — a jump of a
        // full bubble width minus a pet width — the instant a drag crosses the
        // middle of the display. Keep the established edge while it still fits
        // the safe area so the bubble only changes sides when it has to.
        let safeFrame = screenFrame.isEmpty
            ? screenFrame
            : screenFrame.insetBy(dx: 8, dy: 8)
        let alignLeft: Bool
        if let previous = previousAnchor,
           previous.alignsLeft != midlineAlignsLeft,
           !screenFrame.isEmpty
        {
            let previousX = attachedX(alignsLeft: previous.alignsLeft)
            let fits = previousX - bubbleSize.width / 2 >= safeFrame.minX
                && previousX + bubbleSize.width / 2 <= safeFrame.maxX
            alignLeft = fits ? previous.alignsLeft : midlineAlignsLeft
        } else {
            alignLeft = midlineAlignsLeft
        }
        // Horizontal placement is the only part that adapts to a screen edge.
        // The pet keeps its own position, so the bubble slides along the pet's
        // top or bottom edge until it fits instead of being pushed away from it.
        let attachedX = screenFrame.isEmpty
            ? attachedX(alignsLeft: alignLeft)
            : clamp(
                attachedX(alignsLeft: alignLeft),
                lower: safeFrame.minX + bubbleSize.width / 2,
                upper: safeFrame.maxX - bubbleSize.width / 2
            )

        // The bubble hangs off the pet's top or bottom edge and nowhere else,
        // always at the same authored gap. Vertical position is therefore never
        // clamped: an edge flips the side instead of shortening the distance,
        // so the pair keeps one rigid shape wherever the pet is dragged.
        func center(for direction: OverlayBubbleAnchorDirection) -> CGPoint {
            switch direction {
            case .above:
                CGPoint(x: attachedX, y: petTop + bubbleGap + bubbleSize.height / 2)
            case .below:
                CGPoint(x: attachedX, y: petBottom - bubbleGap - bubbleSize.height / 2)
            }
        }
        func fits(_ direction: OverlayBubbleAnchorDirection) -> Bool {
            guard !screenFrame.isEmpty else { return true }
            let candidate = center(for: direction)
            return candidate.y - bubbleSize.height / 2 >= safeFrame.minY
                && candidate.y + bubbleSize.height / 2 <= safeFrame.maxY
        }

        /// How much of the bubble the safe area can show on one side. Used only
        /// to break a tie when a session stack is taller than the room on both
        /// sides; the gap itself is never traded away for visible area.
        func visibleHeight(_ direction: OverlayBubbleAnchorDirection) -> CGFloat {
            guard !screenFrame.isEmpty else { return bubbleSize.height }
            let candidate = center(for: direction)
            let overlap = min(candidate.y + bubbleSize.height / 2, safeFrame.maxY)
                - max(candidate.y - bubbleSize.height / 2, safeFrame.minY)
            return max(0, overlap)
        }

        let preferred = previousAnchor?.direction ?? .above
        let direction: OverlayBubbleAnchorDirection = if fits(preferred) {
            preferred
        } else if fits(preferred.opposite) {
            preferred.opposite
        } else if visibleHeight(preferred.opposite) > visibleHeight(preferred) {
            // A stack taller than the display fits on neither side. Show as much
            // of it as possible at the authored distance instead of sliding it
            // over the pet.
            preferred.opposite
        } else {
            preferred
        }
        return (
            center(for: direction),
            OverlayBubbleAnchor(direction: direction, alignsLeft: alignLeft)
        )
    }

    static func bubbleAlignsLeft(petScreenCenter: CGPoint, screenFrame: CGRect) -> Bool {
        screenFrame.isEmpty ? false : petScreenCenter.x < screenFrame.midX
    }

    static func rect(center: CGPoint, size: CGSize) -> CGRect {
        CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func screenRect(forTopLeftRect rect: CGRect, panelFrame: CGRect) -> CGRect {
        CGRect(
            x: panelFrame.minX + rect.minX,
            y: panelFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func petDragSize(displayWidthPt: CGFloat) -> CGSize {
        let visible = petVisibleSize(displayWidthPt: displayWidthPt)
        return CGSize(
            width: max(26, visible.width * 0.78),
            height: max(38, visible.height * 0.90)
        )
    }

    static func petVisibleSize(displayWidthPt: CGFloat) -> CGSize {
        let width = clampedDisplayWidthPt(displayWidthPt)
        return CGSize(
            width: width,
            height: width * displayAspectHeightRatio
        )
    }

    static func petVisualVerticalOffsets(
        displayWidthPt: CGFloat,
        envelope: OverlayPetVisualEnvelope?
    ) -> (bottom: CGFloat, top: CGFloat) {
        let bounds = fittedPetVisualBounds(
            displayWidthPt: displayWidthPt,
            envelope: envelope
        )
        return (bounds.minY, bounds.maxY)
    }

    static func petVisualHorizontalOffsets(
        displayWidthPt: CGFloat,
        envelope: OverlayPetVisualEnvelope?
    ) -> (left: CGFloat, right: CGFloat) {
        let bounds = fittedPetVisualBounds(
            displayWidthPt: displayWidthPt,
            envelope: envelope
        )
        return (bounds.minX, bounds.maxX)
    }

    private static func fittedPetVisualBounds(
        displayWidthPt: CGFloat,
        envelope: OverlayPetVisualEnvelope?
    ) -> CGRect {
        let spriteSize = petVisibleSize(displayWidthPt: displayWidthPt)
        guard
            let envelope,
            envelope.canvasSize.width > 0,
            envelope.canvasSize.height > 0,
            !envelope.visibleBounds.isEmpty
        else {
            return rect(center: .zero, size: spriteSize)
        }

        let canvasBounds = CGRect(origin: .zero, size: envelope.canvasSize)
        let visibleBounds = envelope.visibleBounds.intersection(canvasBounds)
        guard !visibleBounds.isNull, !visibleBounds.isEmpty else {
            return rect(center: .zero, size: spriteSize)
        }

        let fittedScale = min(
            spriteSize.width / envelope.canvasSize.width,
            spriteSize.height / envelope.canvasSize.height
        )
        let fittedCanvasWidth = envelope.canvasSize.width * fittedScale
        let fittedCanvasHeight = envelope.canvasSize.height * fittedScale
        let fittedCanvasLeft = -spriteSize.width / 2
            + (spriteSize.width - fittedCanvasWidth) / 2
        let fittedCanvasBottom = -spriteSize.height / 2
            + (spriteSize.height - fittedCanvasHeight) / 2
        return CGRect(
            x: fittedCanvasLeft + visibleBounds.minX * fittedScale,
            y: fittedCanvasBottom + visibleBounds.minY * fittedScale,
            width: visibleBounds.width * fittedScale,
            height: visibleBounds.height * fittedScale
        )
    }

    static func clampedDisplayWidthPt(_ displayWidthPt: CGFloat) -> CGFloat {
        guard displayWidthPt.isFinite else { return defaultDisplayWidthPt }
        return min(
            maximumDisplayWidthPt,
            max(minimumDisplayWidthPt, displayWidthPt)
        )
    }

    static func resolvedInitialDisplayWidthPt(
        persistedDisplayWidthPt: CGFloat,
        hasPersistedPosition: Bool
    ) -> CGFloat {
        guard hasPersistedPosition,
              persistedDisplayWidthPt.isFinite,
              persistedDisplayWidthPt > 0 else {
            return defaultDisplayWidthPt
        }
        return clampedDisplayWidthPt(persistedDisplayWidthPt)
    }

    static func bottomAnchoredCenter(
        from center: CGPoint,
        currentDisplayWidthPt: CGFloat,
        proposedDisplayWidthPt: CGFloat
    ) -> CGPoint {
        let currentHeight = petVisibleSize(
            displayWidthPt: currentDisplayWidthPt
        ).height
        let proposedHeight = petVisibleSize(
            displayWidthPt: proposedDisplayWidthPt
        ).height
        let bottomAnchorY = center.y - currentHeight / 2
        return CGPoint(
            x: center.x,
            y: bottomAnchorY + proposedHeight / 2
        )
    }

    static func menuCenter(
        petCenter: CGPoint,
        displayWidthPt: CGFloat,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> CGPoint {
        let petRight = petVisualHorizontalOffsets(
            displayWidthPt: displayWidthPt,
            envelope: petVisualEnvelope
        ).right
        return CGPoint(
            x: petCenter.x + petRight + petControlTrailingGap,
            y: petCenter.y + menuLocalVerticalOffset(
                displayWidthPt: displayWidthPt,
                envelope: petVisualEnvelope
            )
        )
    }

    static func menuScreenCenter(
        petScreenCenter: CGPoint,
        displayWidthPt: CGFloat,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> CGPoint {
        let petRight = petVisualHorizontalOffsets(
            displayWidthPt: displayWidthPt,
            envelope: petVisualEnvelope
        ).right
        return CGPoint(
            x: petScreenCenter.x + petRight + petControlTrailingGap,
            y: petScreenCenter.y - menuLocalVerticalOffset(
                displayWidthPt: displayWidthPt,
                envelope: petVisualEnvelope
            )
        )
    }

    private static func menuLocalVerticalOffset(
        displayWidthPt: CGFloat,
        envelope: OverlayPetVisualEnvelope?
    ) -> CGFloat {
        let petTop = petVisualVerticalOffsets(
            displayWidthPt: displayWidthPt,
            envelope: envelope
        ).top
        return -petTop + menuHitSize.height / 2 + petMenuToPetGap
    }

    static func petPanelScreenFrame(
        displayWidthPt: CGFloat,
        petScreenCenter: CGPoint,
        clickMenuEnabled: Bool
    ) -> CGRect {
        petInteractiveScreenBounds(
            displayWidthPt: displayWidthPt,
            petScreenCenter: petScreenCenter,
            clickMenuEnabled: clickMenuEnabled
        ).integral
    }

    static func petInteractiveScreenBounds(
        displayWidthPt: CGFloat,
        petScreenCenter: CGPoint,
        clickMenuEnabled: Bool
    ) -> CGRect {
        let visibleSize = petVisibleSize(displayWidthPt: displayWidthPt)
        let stageSize = CGSize(
            width: visibleSize.width + petStagePadding,
            height: visibleSize.height + petStagePadding
        )
        let stage = rect(center: petScreenCenter, size: stageSize)
        var bounds = CGRect(
            x: stage.minX - petShadowRadius,
            y: stage.minY - petShadowRadius - petShadowYOffset,
            width: stage.width + petShadowRadius * 2,
            height: stage.height + petShadowRadius * 2
        )

        if clickMenuEnabled {
            bounds = bounds.union(rect(
                center: menuScreenCenter(
                    petScreenCenter: petScreenCenter,
                    displayWidthPt: displayWidthPt
                ),
                size: menuHitSize
            ))
        }

        return bounds.insetBy(dx: -panelContentPadding, dy: -panelContentPadding)
    }

    /// Bounds used only for movement clamping. The render panel remains large
    /// enough for shadows and animation, while dragging is constrained by the
    /// pixels that are actually visible plus the two reachable controls. This
    /// prevents transparent sprite padding from creating an invisible wall.
    static func petMovementScreenBounds(
        displayWidthPt: CGFloat,
        petScreenCenter: CGPoint,
        clickMenuEnabled: Bool,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> CGRect {
        var bounds = fittedPetVisualBounds(
            displayWidthPt: displayWidthPt,
            envelope: petVisualEnvelope
        )
        .offsetBy(dx: petScreenCenter.x, dy: petScreenCenter.y)
        .insetBy(dx: -panelContentPadding, dy: -panelContentPadding)

        if clickMenuEnabled {
            bounds = bounds.union(rect(
                center: menuScreenCenter(
                    petScreenCenter: petScreenCenter,
                    displayWidthPt: displayWidthPt,
                    petVisualEnvelope: petVisualEnvelope
                ),
                size: menuHitSize
            ))
        }

        return bounds.insetBy(dx: -panelContentPadding, dy: -panelContentPadding)
    }

    static func shouldShowControls(
        at screenPoint: CGPoint,
        displayWidthPt: CGFloat,
        petScreenCenter: CGPoint,
        clickMenuEnabled: Bool,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> Bool {
        var regions = [
            petVisualScreenRect(
                displayWidthPt: displayWidthPt,
                petScreenCenter: petScreenCenter,
                petVisualEnvelope: petVisualEnvelope
            ).insetBy(dx: -controlVisibilitySlop, dy: -controlVisibilitySlop)
        ]

        if clickMenuEnabled {
            regions.append(rect(
                center: menuScreenCenter(
                    petScreenCenter: petScreenCenter,
                    displayWidthPt: displayWidthPt,
                    petVisualEnvelope: petVisualEnvelope
                ),
                size: menuHitSize
            ).insetBy(dx: -controlVisibilitySlop, dy: -controlVisibilitySlop))
        }

        return regions.contains { $0.contains(screenPoint) }
    }

    static func petVisualScreenRect(
        displayWidthPt: CGFloat,
        petScreenCenter: CGPoint,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> CGRect {
        let horizontal = petVisualHorizontalOffsets(
            displayWidthPt: displayWidthPt,
            envelope: petVisualEnvelope
        )
        let vertical = petVisualVerticalOffsets(
            displayWidthPt: displayWidthPt,
            envelope: petVisualEnvelope
        )
        return CGRect(
            x: petScreenCenter.x + horizontal.left,
            y: petScreenCenter.y + vertical.bottom,
            width: max(0, horizontal.right - horizontal.left),
            height: max(0, vertical.top - vertical.bottom)
        )
    }

    /// Maps a top-left panel point through the same aspect-fit transform used
    /// by `PetMetalFrameRenderer`. The frame image is centered horizontally in
    /// its animation canvas and bottom-aligned; the resulting image point is
    /// then sampled from the immutable one-bit alpha mask.
    static func petFrameContainsOpaquePixel(
        atTopLeftPoint point: CGPoint,
        displayWidthPt: CGFloat,
        petCenter: CGPoint,
        frameHitTest: OverlayPetFrameHitTest
    ) -> Bool {
        guard displayWidthPt.isFinite, displayWidthPt > 0,
              point.x.isFinite, point.y.isFinite,
              frameHitTest.canvasSize.width.isFinite,
              frameHitTest.canvasSize.height.isFinite,
              frameHitTest.canvasSize.width > 0,
              frameHitTest.canvasSize.height > 0 else {
            return false
        }

        let drawableSize = petVisibleSize(displayWidthPt: displayWidthPt)
        let drawableRect = rect(center: petCenter, size: drawableSize)
        guard drawableRect.contains(point) else { return false }

        let fittedScale = min(
            drawableSize.width / frameHitTest.canvasSize.width,
            drawableSize.height / frameHitTest.canvasSize.height
        )
        guard fittedScale.isFinite, fittedScale > 0 else { return false }

        let fittedCanvasSize = CGSize(
            width: frameHitTest.canvasSize.width * fittedScale,
            height: frameHitTest.canvasSize.height * fittedScale
        )
        let fittedCanvasOrigin = CGPoint(
            x: (drawableSize.width - fittedCanvasSize.width) / 2,
            y: (drawableSize.height - fittedCanvasSize.height) / 2
        )
        let localBottomLeftPoint = CGPoint(
            x: point.x - drawableRect.minX,
            y: drawableRect.maxY - point.y
        )
        let canvasPoint = CGPoint(
            x: (localBottomLeftPoint.x - fittedCanvasOrigin.x) / fittedScale,
            y: (localBottomLeftPoint.y - fittedCanvasOrigin.y) / fittedScale
        )
        let imageOriginInCanvas = CGPoint(
            x: max(
                0,
                (frameHitTest.canvasSize.width
                    - CGFloat(frameHitTest.alphaMask.pixelWidth)) / 2
            ),
            y: 0
        )
        return frameHitTest.alphaMask.containsOpaquePixel(atBottomLeftPoint: CGPoint(
            x: canvasPoint.x - imageOriginInCanvas.x,
            y: canvasPoint.y - imageOriginInCanvas.y
        ))
    }

    static func dragTargetDisplay(
        pointer: CGPoint,
        proposedPetCenter: CGPoint,
        displays: [OverlayDisplayGeometry],
        fallback: OverlayDisplayGeometry
    ) -> OverlayDisplayGeometry {
        displays.first(where: { $0.frame.contains(pointer) })
            ?? displays.first(where: { $0.frame.contains(proposedPetCenter) })
            ?? fallback
    }

    static func bubblePanelScreenFrame(
        displayWidthPt: CGFloat,
        petScreenCenter: CGPoint,
        visibleFrame: CGRect,
        content: OverlayBubbleContent = .measurementPlaceholder,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil,
        fontScale: BubbleFontScale = .standard
    ) -> CGRect {
        bubblePanelScreenFrame(
            displayWidthPt: displayWidthPt,
            petScreenCenter: petScreenCenter,
            visibleFrame: visibleFrame,
            contents: [content],
            petVisualEnvelope: petVisualEnvelope,
            fontScale: fontScale
        )
    }

    static func bubblePanelScreenFrame(
        displayWidthPt: CGFloat,
        petScreenCenter: CGPoint,
        visibleFrame: CGRect,
        contents: [OverlayBubbleContent],
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil,
        fontScale: BubbleFontScale = .standard
    ) -> CGRect {
        bubblePanelLayout(
            displayWidthPt: displayWidthPt,
            petScreenCenter: petScreenCenter,
            visibleFrame: visibleFrame,
            contents: contents,
            petVisualEnvelope: petVisualEnvelope,
            previousAnchor: nil,
            fontScale: fontScale
        ).frame
    }

    static func bubblePanelLayout(
        displayWidthPt: CGFloat,
        petScreenCenter: CGPoint,
        visibleFrame: CGRect,
        contents: [OverlayBubbleContent],
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil,
        previousAnchor: OverlayBubbleAnchor?,
        fontScale: BubbleFontScale = .standard
    ) -> OverlayBubblePanelLayout {
        let bubbleSize = resolvedBubbleStackSize(
            in: visibleFrame.size,
            contents: contents,
            fontScale: fontScale
        )
        guard bubbleSize.width > 0, bubbleSize.height > 0 else {
            return OverlayBubblePanelLayout(
                frame: .zero,
                anchor: previousAnchor
                    ?? OverlayBubbleAnchor(direction: .above, alignsLeft: false)
            )
        }
        let placement = bubblePlacement(
            bubbleSize: bubbleSize,
            displayWidthPt: displayWidthPt,
            petScreenCenter: petScreenCenter,
            screenFrame: visibleFrame,
            petVisualEnvelope: petVisualEnvelope,
            previousAnchor: previousAnchor
        )
        return OverlayBubblePanelLayout(
            frame: rect(
                center: placement.center,
                size: bubbleSize
            ).integral,
            anchor: placement.anchor
        )
    }

    static func panelScreenFrame(
        displayWidthPt: CGFloat,
        petScreenCenter: CGPoint,
        bubbleVisible: Bool,
        clickMenuEnabled: Bool,
        visibleFrame: CGRect,
        bubbleContent: OverlayBubbleContent = .measurementPlaceholder
    ) -> CGRect {
        let bubbleSize = resolvedBubbleSize(in: visibleFrame.size, content: bubbleContent)
        var rects = [
            rect(
                center: petScreenCenter,
                size: petVisibleSize(displayWidthPt: displayWidthPt)
            )
        ]

        if clickMenuEnabled {
            rects.append(rect(
                center: menuScreenCenter(
                    petScreenCenter: petScreenCenter,
                    displayWidthPt: displayWidthPt
                ),
                size: menuHitSize
            ))
        }

        if bubbleVisible {
            rects.append(rect(
                center: bubbleScreenCenter(
                    bubbleSize: bubbleSize,
                    displayWidthPt: displayWidthPt,
                    petScreenCenter: petScreenCenter,
                    screenFrame: visibleFrame
                ),
                size: bubbleSize
            ))
        }

        let union = rects.dropFirst().reduce(rects[0]) { partial, rect in
            partial.union(rect)
        }
        return union.insetBy(dx: -8, dy: -8).integral
    }

    static func interactiveRects(
        in containerSize: CGSize,
        displayWidthPt: CGFloat,
        petCenter: CGPoint,
        bubbleVisible: Bool,
        clickMenuEnabled: Bool,
        panelFrame: CGRect,
        screenFrame: CGRect,
        includeBubble: Bool,
        bubbleContent: OverlayBubbleContent = .measurementPlaceholder
    ) -> [CGRect] {
        let displayPetCenter = petCenter
        let menuCenter = menuCenter(
            petCenter: displayPetCenter,
            displayWidthPt: displayWidthPt
        )
        var rects: [CGRect] = [
            rect(
                center: displayPetCenter,
                size: petVisibleSize(displayWidthPt: displayWidthPt)
            )
        ]

        if clickMenuEnabled {
            rects.append(rect(center: menuCenter, size: menuHitSize))
        }

        if bubbleVisible && includeBubble {
            let bubbleSize = resolvedBubbleSize(in: screenFrame.size, content: bubbleContent)
            let center = bubblePosition(
                bubbleSize: bubbleSize,
                displayWidthPt: displayWidthPt,
                petCenter: displayPetCenter,
                panelFrame: panelFrame,
                screenFrame: screenFrame,
                in: containerSize
            )
            rects.append(rect(center: center, size: bubbleSize))
        }

        return rects
    }

    static func shouldHandleMouse(
        atTopLeftPoint point: CGPoint,
        in containerSize: CGSize,
        displayWidthPt: CGFloat,
        petCenter: CGPoint,
        bubbleVisible: Bool,
        clickMenuEnabled: Bool,
        panelFrame: CGRect,
        screenFrame: CGRect,
        includeBubble: Bool,
        bubbleContent: OverlayBubbleContent = .measurementPlaceholder,
        petFrameHitTest: OverlayPetFrameHitTest? = nil,
        overlayVisible: Bool = true,
        primaryButtonDown: Bool = false,
        activeInteractionID: UUID? = nil,
        maskState: OverlayPointerMaskState? = nil
    ) -> Bool {
        guard overlayVisible else { return false }
        let rects = interactiveRects(
            in: containerSize,
            displayWidthPt: displayWidthPt,
            petCenter: petCenter,
            bubbleVisible: bubbleVisible,
            clickMenuEnabled: clickMenuEnabled,
            panelFrame: panelFrame,
            screenFrame: screenFrame,
            includeBubble: includeBubble,
            bubbleContent: bubbleContent
        )
        let pointerInsidePanel = CGRect(
            origin: .zero,
            size: containerSize
        ).contains(point)
        let petDragRect = rects.first ?? .zero
        let auxiliaryHit = pointerInsidePanel
            && rects.dropFirst().contains(where: { $0.contains(point) })
        let geometricPetHit = pointerInsidePanel && petDragRect.contains(point)
        let resolvedMaskState = maskState
            ?? (petFrameHitTest == nil ? .missing : .valid)
        let opaque = resolvedMaskState == .valid
            && geometricPetHit
            && petFrameHitTest.map {
                petFrameContainsOpaquePixel(
                    atTopLeftPoint: point,
                    displayWidthPt: displayWidthPt,
                    petCenter: petCenter,
                    frameHitTest: $0
                )
            } == true
        return OverlayPointerOwnershipPolicy.resolve(
            OverlayPointerOwnershipInput(
                overlayVisible: overlayVisible,
                primaryButtonDown: primaryButtonDown,
                activeInteractionID: activeInteractionID,
                maskState: resolvedMaskState,
                validMaskPixelIsOpaque: opaque,
                pointerInBubble: includeBubble && auxiliaryHit,
                pointerInMenu: clickMenuEnabled && auxiliaryHit,
                pointerInGeometricPetRegion: geometricPetHit
            )
        ).isOwnedByOverlay
    }

    private static func measuredBubbleHeight(
        width: CGFloat,
        content: OverlayBubbleContent,
        fontScale: BubbleFontScale
    ) -> CGFloat {
        let rowHeights = bubbleSessionRowHeights(
            bubbleWidth: width,
            content: content,
            fontScale: fontScale
        )
        if content.isStandaloneSessionCard {
            return ceil(
                bubbleVerticalPadding * 2
                    + (rowHeights.first ?? 0)
                    + content.stackDecorationDepth
            )
        }
        let dividers = CGFloat(max(0, rowHeights.count - 1)) * bubbleSessionDividerHeight
        return ceil(
            bubbleVerticalPadding * 2
                + bubbleGroupHeaderHeight(fontScale: fontScale)
                + bubbleGroupHeaderSpacing
                + rowHeights.reduce(0, +)
                + dividers
                + content.stackDecorationDepth
        )
    }

    private static func measuredSessionRowHeight(
        width _: CGFloat,
        session _: OverlaySessionContent,
        isStandaloneSessionCard: Bool,
        fontScale: BubbleFontScale
    ) -> CGFloat {
        if isStandaloneSessionCard {
            let metadataHeight = max(
                bubbleHeaderAvatarWidth,
                lineHeight(for: OverlayBubbleTypography.measurementFont(
                    .caption1,
                    scale: fontScale
                ))
            )
            return ceil(
                bubbleSessionVerticalPadding * 2
                    + metadataHeight
                    + bubbleStandaloneMetadataSpacing
                    + bubbleStandaloneSummaryTextHeight(fontScale: fontScale)
            )
        }
        // Reserve the full two-line detail region. Tool activity often changes
        // between one and two lines; allowing that to resize an NSPanel on
        // every hook makes the whole bubble stack visibly jump.
        return ceil(
            bubbleSessionVerticalPadding * 2
                + bubbleDetailedHeaderHeight(fontScale: fontScale)
                + bubbleSessionTitleSpacing
                + bubbleDetailTextHeight(fontScale: fontScale)
        )
    }

    private static func measuredSingleLineWidth(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return ceil((text as NSString).size(withAttributes: attributes).width)
    }

    private static func measuredTextHeight(
        _ text: String,
        font: NSFont,
        width: CGFloat,
        lineHeight: CGFloat,
        maximumLines: Int
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph
        ]
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let measuredLines = max(1, Int(ceil(bounds.height / max(1, lineHeight))))
        return CGFloat(min(maximumLines, measuredLines)) * lineHeight
    }

    private static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard lower <= upper else { return (lower + upper) / 2 }
        return min(max(value, lower), upper)
    }

    /// Quantizes both hard bounds inward before clamping a canonical center.
    /// This ordering prevents a rounded edge coordinate from escaping the
    /// visible screen after an otherwise correct geometric clamp.
    private static func inwardCanonicalClamp(
        _ value: CGFloat,
        lower: CGFloat,
        upper: CGFloat
    ) -> CGFloat {
        guard let canonicalLower = OverlayPlacementCanonicalization
            .inwardLowerBound(Double(lower)),
            let canonicalUpper = OverlayPlacementCanonicalization
                .inwardUpperBound(Double(upper)),
            let canonicalValue = OverlayPlacementCanonicalization.coordinate(
                Double(value)
            ) else {
            return clamp(value, lower: lower, upper: upper)
        }
        guard canonicalLower <= canonicalUpper else {
            let midpoint = (lower + upper) / 2
            return CGFloat(
                OverlayPlacementCanonicalization.coordinate(Double(midpoint))
                    ?? Double(midpoint)
            )
        }
        return CGFloat(min(
            max(canonicalValue, canonicalLower),
            canonicalUpper
        ))
    }
}

enum OverlaySessionGroupTone: Int, CaseIterable, Equatable {
    case running = 0
    case ready = 1
    case failed = 2
    case needsInput = 3

    init(eventType: AgentEventKind?) {
        self = switch eventType {
        case .waiting: .needsInput
        case .failed: .failed
        case .done: .ready
        case .start, .thinking, .plan, .tool, nil: .running
        }
    }

    static func aggregate(_ sessions: [OverlaySessionContent]) -> OverlaySessionGroupTone {
        sessions
            .map { OverlaySessionGroupTone(eventType: $0.eventType) }
            .max(by: { $0.rawValue < $1.rawValue })
            ?? .running
    }
}

enum OverlayBubbleProjection {
    static func contents(
        states: [ActiveAgentState],
        omittedCount: Int,
        dismissedSessionIDs: Set<String>,
        groupSessionsByAgent: Bool = true,
        standaloneSessionOrder: [String] = [],
        standaloneStackExpanded: Bool = true,
        isExpanded: (AgentSource) -> Bool
    ) -> [OverlayBubbleContent] {
        let visibleStates = states.filter {
            !dismissedSessionIDs.contains(OverlaySessionContent.stableID(
                source: $0.source,
                sessionID: $0.sessionID ?? $0.event.sessionID,
                anonymousSessionAlias: $0.anonymousSessionAlias,
                fallbackEventID: $0.event.id
            ))
        }
        if !groupSessionsByAgent {
            let stateByID = Dictionary(
                visibleStates.map { state in
                    (
                        OverlaySessionContent.stableID(
                            source: state.source,
                            sessionID: state.sessionID ?? state.event.sessionID,
                            anonymousSessionAlias: state.anonymousSessionAlias,
                            fallbackEventID: state.event.id
                        ),
                        state
                    )
                },
                uniquingKeysWith: { _, latest in latest }
            )
            var orderedStates = standaloneSessionOrder.compactMap { stateByID[$0] }
            let orderedIDs = Set(orderedStates.map {
                OverlaySessionContent.stableID(
                    source: $0.source,
                    sessionID: $0.sessionID ?? $0.event.sessionID,
                    anonymousSessionAlias: $0.anonymousSessionAlias,
                    fallbackEventID: $0.event.id
                )
            })
            // Direct projection callers may not own App presentation state.
            // Use PetCore's canonical attention/latest-first order as the
            // fallback so the first expanded card matches the folded card.
            orderedStates.append(contentsOf: visibleStates.filter {
                !orderedIDs.contains(OverlaySessionContent.stableID(
                    source: $0.source,
                    sessionID: $0.sessionID ?? $0.event.sessionID,
                    anonymousSessionAlias: $0.anonymousSessionAlias,
                    fallbackEventID: $0.event.id
                ))
            })
            // The visual list is priority-first. Stable presentation order is
            // retained inside a tone so ordinary thinking/tool churn cannot
            // make concurrent cards hop.
            orderedStates = orderedStates.enumerated().sorted { left, right in
                let leftTone = OverlaySessionGroupTone(eventType: left.element.event.eventType)
                let rightTone = OverlaySessionGroupTone(eventType: right.element.event.eventType)
                if leftTone != rightTone {
                    return leftTone.rawValue > rightTone.rawValue
                }
                return left.offset < right.offset
            }.map(\.element)

            let representedSessionCount = orderedStates.count + omittedCount
            if !standaloneStackExpanded,
               representedSessionCount > 1,
               let primaryState = orderedStates.first
            {
                return [OverlayBubbleContent(
                    standaloneState: primaryState,
                    stackSessionCount: representedSessionCount,
                    isStackExpanded: false
                )]
            }
            var cards = orderedStates.enumerated().map { index, state in
                OverlayBubbleContent(
                    standaloneState: state,
                    stackSessionCount: index == 0
                        ? representedSessionCount
                        : 1,
                    isStackExpanded: true
                )
            }
            if omittedCount > 0 {
                cards.append(.omittedSummary(count: omittedCount))
            }
            return cards
        }

        var grouped = AgentSource.allCases.compactMap { source -> OverlayBubbleContent? in
            let sourceStates = visibleStates.filter { $0.source == source }
            return sourceStates.isEmpty ? nil : OverlayBubbleContent(
                source: source,
                states: sourceStates,
                isExpanded: isExpanded(source)
            )
        }
        if omittedCount > 0 {
            grouped.append(.omittedSummary(count: omittedCount))
        }
        // The pet itself communicates idle. No session means no bubble.
        return grouped
    }
}

enum OverlaySessionSurfaceKind: Equatable {
    case app
    case cli
}

enum OverlaySessionNavigationNotice: Equatable, Sendable {
    case unavailable
    case failed
    case degradedToHost

    func localizedText(
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        switch self {
        case .unavailable:
            APCLocalization.text(.overlaySessionNavigationUnavailable, locale: locale)
        case .failed:
            APCLocalization.text(.overlaySessionNavigationFailed, locale: locale)
        case .degradedToHost:
            APCLocalization.text(.overlaySessionNavigationDegraded, locale: locale)
        }
    }
}

struct OverlaySessionContent: Equatable, Identifiable {
    var id: String
    var eventID: String
    var source: AgentSource?
    var sessionID: String?
    var eventType: AgentEventKind?
    var sessionTitle: String
    var activityText: String
    var messageText: String
    var statusText: String
    var acknowledgementID: String?
    var navigation: AgentSessionNavigation
    var navigationNotice: OverlaySessionNavigationNotice?

    var needsUserAttention: Bool {
        eventType == .waiting || eventType == .failed
    }

    var navigationCapability: NavigationCapability {
        AgentSessionRouter.validatedCapability(
            source: source,
            sessionID: sessionID,
            navigation: navigation
        )
    }
    var canOpen: Bool {
        source == nil || navigationCapability != .unavailable
    }
    var actionLabel: String {
        actionLabel()
    }
    func actionLabel(
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        guard let source else {
            return APCLocalization.text(.overlayActionOpen, locale: locale)
        }
        return APCLocalizedPresentation.navigationActionTitle(
            navigationCapability,
            source: source,
            navigation: navigation,
            locale: locale
        ) ?? APCLocalizedPresentation.navigationUnavailableTitle(locale: locale)
    }
    var surfaceKind: OverlaySessionSurfaceKind? {
        switch navigation.surface {
        case "chatgpt_app", "claude_app", "opencode_app":
            .app
        case "cli_terminal":
            .cli
        default:
            nil
        }
    }
    var surfaceLabel: String? {
        surfaceLabel()
    }
    func surfaceLabel(
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String? {
        surfaceKind.map {
            APCLocalizedPresentation.sessionSurfaceTitle($0, locale: locale)
        }
    }
    var secondaryDetailText: String? {
        let details = detailCandidates
        guard let primary = details.first else { return nil }
        return details.dropFirst().first {
            Self.normalizedText($0) != Self.normalizedText(primary)
        }
    }
    var primaryDetailText: String {
        detailCandidates.first ?? ""
    }
    var standaloneSummaryText: String {
        primaryDetailText.isEmpty ? statusText : primaryDetailText
    }
    var detailText: String {
        [primaryDetailText, secondaryDetailText]
            .compactMap { $0 }
            .joined(separator: "\n")
    }
    var accessibilityReadingOrder: [String] {
        [
            source?.title,
            surfaceLabel,
            sessionTitle,
            statusText,
            primaryDetailText,
            secondaryDetailText,
            accessibilityFallbackDetailText,
            actionLabel,
        ]
        .compactMap(Self.compactMessage)
    }
    var accessibilityLabel: String {
        accessibilityReadingOrder.joined(separator: ", ")
    }
    private var detailCandidates: [String] {
        [
            navigationNotice?.localizedText(),
            Self.compactMessage(messageText),
            Self.compactMessage(activityText),
        ].compactMap { $0 }
    }
    /// Preserves a complete VoiceOver state-to-action reading order when
    /// PetCore intentionally omits displayable session copy. This text is
    /// localized product guidance, never raw connector event detail, and is
    /// not inserted into the visual bubble.
    private var accessibilityFallbackDetailText: String? {
        guard detailCandidates.isEmpty else { return nil }
        let key: APCLocalizationKey? = switch eventType {
        case .start:
            .overlayDetailRunning
        case .thinking:
            .overlayActivityThinking
        case .plan:
            .overlayActivityPlan
        case .tool:
            .overlayActivityTool
        case .waiting:
            .overlayDetailNeedsInput
        case .done:
            .overlayDetailCompleted
        case .failed:
            .overlayDetailBlocked
        case nil:
            nil
        }
        guard let key else { return nil }
        return Self.compactMessage(Self.nonredundantDetail(
            APCLocalization.text(key),
            title: sessionTitle,
            status: statusText
        ))
    }
    var dismissesAfterActivation: Bool {
        switch eventType {
        case .done: true
        case .start, .thinking, .plan, .tool, .waiting, .failed, nil: false
        }
    }

    /// Geometry-only fixture for callers that do not have live bubble
    /// content. AppStore never publishes this as a user-visible session.
    static let measurementPlaceholder = OverlaySessionContent(
        id: "measurement-placeholder",
        eventID: "measurement-placeholder",
        source: nil,
        sessionID: nil,
        eventType: nil,
        sessionTitle: "Agent Pet Companion",
        activityText: "",
        messageText: "",
        statusText: "",
        navigation: AgentSessionNavigation()
    )

    static func omittedSummary(count: Int) -> OverlaySessionContent {
        OverlaySessionContent(
            id: "omitted-session-summary",
            eventID: "omitted-session-summary",
            source: nil,
            sessionID: nil,
            eventType: nil,
            sessionTitle: APCLocalization.text(.overlayMoreSessionsTitle),
            activityText: "",
            messageText: APCLocalization.format(.overlayMoreSessionsDetailFormat, count),
            statusText: "",
            navigation: AgentSessionNavigation()
        )
    }

    init(
        id: String,
        eventID: String? = nil,
        source: AgentSource?,
        sessionID: String?,
        eventType: AgentEventKind?,
        sessionTitle: String,
        activityText: String? = nil,
        messageText: String,
        statusText: String,
        acknowledgementID: String? = nil,
        navigation: AgentSessionNavigation = AgentSessionNavigation(),
        navigationNotice: OverlaySessionNavigationNotice? = nil
    ) {
        self.id = id
        self.eventID = eventID ?? id
        self.source = source
        self.sessionID = sessionID
        self.eventType = eventType
        self.sessionTitle = sessionTitle
        self.activityText = activityText ?? ""
        self.messageText = messageText
        self.statusText = statusText
        self.acknowledgementID = acknowledgementID
        self.navigation = navigation
        self.navigationNotice = navigationNotice
    }

    init(state: ActiveAgentState) {
        let event = state.event
        let resolvedSessionID = state.sessionID ?? event.sessionID
        id = Self.stableID(
            source: event.source,
            sessionID: resolvedSessionID,
            anonymousSessionAlias: state.anonymousSessionAlias,
            fallbackEventID: event.id
        )
        eventID = event.id
        source = event.source
        sessionID = resolvedSessionID
        eventType = event.eventType
        acknowledgementID = state.acknowledgementID
        statusText = Self.displayStatus(
            for: state.overlayDisplay?.summaryKind
                ?? Self.summaryKind(for: event.eventType)
        )
        let proposedTitle = Self.sessionTitle(for: state)
        sessionTitle = Self.normalizedText(proposedTitle) == Self.normalizedText(statusText)
            ? Self.genericSessionTitle(for: state)
            : proposedTitle
        navigation = state.overlayDisplay?.navigation ?? AgentSessionNavigation()
        navigationNotice = nil
        activityText = Self.nonredundantDetail(
            Self.activityDetail(for: state),
            title: sessionTitle,
            status: statusText
        )
        messageText = Self.nonredundantMessage(
            Self.assistantMessage(for: state) ?? "",
            title: sessionTitle,
            status: statusText
        )
    }

    init(event: AgentEvent) {
        id = Self.stableID(
            source: event.source,
            sessionID: event.sessionID,
            fallbackEventID: event.id
        )
        eventID = event.id
        source = event.source
        sessionID = event.sessionID
        eventType = event.eventType
        acknowledgementID = nil
        sessionTitle = APCLocalization.format(.overlaySessionTitleFormat, event.source.shortTitle)
        statusText = Self.displayStatus(for: Self.summaryKind(for: event.eventType))
        navigation = event.sessionNavigation
        navigationNotice = nil
        activityText = ""
        messageText = ""
    }

    static func stableID(
        source: AgentSource,
        sessionID: String?,
        anonymousSessionAlias: String? = nil,
        fallbackEventID _: String
    ) -> String {
        let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sessionID, !sessionID.isEmpty else {
            if let anonymousSessionAlias = validatedAnonymousAlias(anonymousSessionAlias) {
                return "session-\(source.rawValue)-\(anonymousSessionAlias)"
            }
            // PetCore groups unattributed events into one source-scoped session.
            // Match that identity here so hook revisions update the existing row
            // instead of removing/reinserting it and clearing manual dismissal.
            return "session-\(source.rawValue)-unattributed"
        }
        return "session-\(source.rawValue)-\(sessionID)"
    }

    static func reopenID(for state: ActiveAgentState) -> String {
        let stableID = stableID(
            source: state.source,
            sessionID: state.sessionID ?? state.event.sessionID,
            anonymousSessionAlias: state.anonymousSessionAlias,
            fallbackEventID: state.event.id
        )
        switch state.event.eventType {
        case .waiting, .failed:
            return "attention:\(stableID):\(state.event.id)"
        case .start, .thinking, .plan, .tool, .done:
            return "activation:\(stableID):\(state.sessionActivatedAt ?? "initial")"
        }
    }

    private static func sessionTitle(for state: ActiveAgentState) -> String {
        if let title = compactTitle(state.sessionTitle) {
            return title
        }
        if state.sessionUserMessage?.role == "user",
           let title = compactTitle(state.sessionUserMessage?.content)
        {
            return title
        }
        return genericSessionTitle(for: state)
    }

    private static func genericSessionTitle(for state: ActiveAgentState) -> String {
        if let label = anonymousAliasLabel(state.anonymousSessionAlias) {
            return APCLocalization.format(
                .overlaySessionAliasTitleFormat,
                state.source.shortTitle,
                label
            )
        }
        return APCLocalization.format(.overlaySessionTitleFormat, state.source.shortTitle)
    }

    static func anonymousAliasLabel(_ value: String?) -> String? {
        guard let value = validatedAnonymousAlias(value),
              value.hasPrefix("anon-"),
              let sequence = UInt64(value.dropFirst(5), radix: 36),
              sequence > 0
        else {
            return nil
        }

        var index = sequence
        var characters: [Character] = []
        while index > 0 {
            index -= 1
            let scalar = UnicodeScalar(65 + Int(index % 26))!
            characters.append(Character(scalar))
            index /= 26
        }
        return String(characters.reversed())
    }

    private static func validatedAnonymousAlias(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.range(
                  of: "^anon-[0-9a-z]{1,13}$",
                  options: .regularExpression
              ) != nil
        else {
            return nil
        }
        return value
    }

    private static func activityDetail(for state: ActiveAgentState) -> String? {
        // Only PetCore's bounded, normalized projection is displayable. Raw
        // connector payloads may contain commands, paths, or serialized JSON.
        compactMessage(state.sessionActivity?.content)
    }

    private static func assistantMessage(for state: ActiveAgentState) -> String? {
        guard state.sessionMessage?.role == "assistant" else { return nil }
        return compactMessage(state.sessionMessage?.content)
    }

    private static func compactTitle(_ value: String?) -> String? {
        guard let value = compactMessage(value) else { return nil }
        let firstLine = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
        return firstLine.count > 80 ? "\(firstLine.prefix(79))…" : firstLine
    }

    private static func compactMessage(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Compiled once instead of per call. `replacingOccurrences(options:
    /// .regularExpression)` builds a fresh `NSRegularExpression` every time,
    /// and this normalization runs several times per session on every bubble
    /// projection. The pattern and match options are unchanged, so the
    /// resulting text is identical.
    private static let redundancyNormalizationPattern = try? NSRegularExpression(
        pattern: "[\\s\\p{P}]+"
    )

    private static func normalizedText(_ value: String) -> String {
        let folded = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard let pattern = redundancyNormalizationPattern else { return folded }
        return pattern.stringByReplacingMatches(
            in: folded,
            range: NSRange(folded.startIndex..., in: folded),
            withTemplate: ""
        )
    }

    private static func nonredundantMessage(
        _ proposed: String,
        title: String,
        status: String
    ) -> String {
        let occupied = Set([title, status].map(normalizedText))
        return occupied.contains(normalizedText(proposed)) ? "" : proposed
    }

    private static func nonredundantDetail(
        _ proposed: String?,
        title: String,
        status: String
    ) -> String {
        guard let proposed = compactMessage(proposed) else { return "" }
        let occupied = Set([title, status].map(normalizedText))
        return occupied.contains(normalizedText(proposed)) ? "" : proposed
    }

    static func displayStatus(for summaryKind: AgentOverlaySummaryKind) -> String {
        APCLocalizedPresentation.overlayEventTitle(summaryKind)
    }

    static func summaryKind(for eventType: AgentEventKind) -> AgentOverlaySummaryKind {
        switch eventType {
        case .start: .start
        case .thinking: .thinking
        case .plan: .plan
        case .tool: .tool
        case .waiting: .needsInput
        case .done: .done
        case .failed: .failed
        }
    }

}

enum OverlayBubbleSessionPrimaryAction: Equatable {
    case expandSessions
    case activateSession

    static func resolve(content: OverlayBubbleContent) -> Self {
        content.isStacked ? .expandSessions : .activateSession
    }
}

struct OverlayBubbleContent: Equatable, Identifiable {
    var id: String
    var source: AgentSource?
    var agentName: String
    var sessions: [OverlaySessionContent]
    var isExpanded: Bool
    var omittedSessionCount: Int
    var isStandaloneSessionCard: Bool
    var standaloneStackSessionCount: Int

    var eventIDs: [String] { sessions.map(\.eventID) }
    var dismissalIDs: [String] { canDismiss ? sessions.map(\.id) : [] }
    var visibleSessions: [OverlaySessionContent] {
        guard !sessions.isEmpty, !isOmittedSummary else { return sessions }
        let ordered = sessions.enumerated().sorted { left, right in
            let leftTone = OverlaySessionGroupTone(eventType: left.element.eventType)
            let rightTone = OverlaySessionGroupTone(eventType: right.element.eventType)
            if leftTone != rightTone {
                return leftTone.rawValue > rightTone.rawValue
            }
            return left.offset < right.offset
        }.map(\.element)
        return isExpanded ? ordered : Array(ordered.prefix(1))
    }
    var sessionCount: Int { sessions.count }
    var representedSessionCount: Int {
        if isStandaloneSessionCard, !isExpanded {
            return disclosureSessionCount
        }
        return omittedSessionCount > 0 ? omittedSessionCount : sessionCount
    }
    var disclosureSessionCount: Int {
        isStandaloneSessionCard
            ? max(sessionCount, standaloneStackSessionCount)
            : sessionCount
    }
    var isOmittedSummary: Bool { omittedSessionCount > 0 }
    var canDismiss: Bool { !isOmittedSummary }
    var hasMultipleSessions: Bool { disclosureSessionCount > 1 }
    var isStacked: Bool { hasMultipleSessions && !isExpanded }
    var stackDecorationLayerCount: Int {
        guard isStacked else { return 0 }
        return min(
            OverlayGeometry.bubbleCollapsedStackLayerCount,
            max(0, disclosureSessionCount - 1)
        )
    }
    var showsStackDecoration: Bool { stackDecorationLayerCount > 0 }
    var stackDecorationDepth: CGFloat {
        let layerOffset = isStandaloneSessionCard
            ? OverlayGeometry.bubbleStandaloneStackLayerOffset
            : OverlayGeometry.bubbleCollapsedStackLayerOffset
        return CGFloat(stackDecorationLayerCount) * layerOffset
    }
    var statusTone: OverlaySessionGroupTone {
        OverlaySessionGroupTone.aggregate(sessions)
    }

    /// Geometry-only fixture; idle product state intentionally emits no
    /// bubble from AppStore.
    static let measurementPlaceholder = OverlayBubbleContent(
        id: "measurement-placeholder",
        source: nil,
        agentName: "Agent Pet Companion",
        sessions: [.measurementPlaceholder],
        isExpanded: true,
        omittedSessionCount: 0,
        isStandaloneSessionCard: false,
        standaloneStackSessionCount: 0
    )

    static func omittedSummary(count: Int) -> OverlayBubbleContent {
        OverlayBubbleContent(
            id: "omitted-session-summary",
            source: nil,
            agentName: "Agent Pet Companion",
            sessions: [.omittedSummary(count: count)],
            isExpanded: true,
            omittedSessionCount: count,
            isStandaloneSessionCard: false,
            standaloneStackSessionCount: 0
        )
    }

    init(
        id: String,
        source: AgentSource?,
        agentName: String,
        sessions: [OverlaySessionContent],
        isExpanded: Bool = true,
        omittedSessionCount: Int = 0,
        isStandaloneSessionCard: Bool = false,
        standaloneStackSessionCount: Int = 0
    ) {
        self.id = id
        self.source = source
        self.agentName = agentName
        self.sessions = sessions
        self.isExpanded = isExpanded
        self.omittedSessionCount = omittedSessionCount
        self.isStandaloneSessionCard = isStandaloneSessionCard
        self.standaloneStackSessionCount = standaloneStackSessionCount
    }

    init(source: AgentSource, states: [ActiveAgentState], isExpanded: Bool = true) {
        id = "agent-\(source.rawValue)"
        self.source = source
        agentName = source.title
        let orderedStates = Array(states
            .enumerated()
            .sorted(by: Self.isMoreRecentlyActivated)
            .prefix(8))
        sessions = orderedStates.map { entry in
            OverlaySessionContent(state: entry.element)
        }
        self.isExpanded = isExpanded
        omittedSessionCount = 0
        isStandaloneSessionCard = false
        standaloneStackSessionCount = 0
    }

    init(state: ActiveAgentState) {
        self.init(source: state.source, states: [state])
    }

    init(
        standaloneState state: ActiveAgentState,
        stackSessionCount: Int = 1,
        isStackExpanded: Bool = true
    ) {
        let session = OverlaySessionContent(state: state)
        self.init(
            id: "session-card-\(session.id)",
            source: state.source,
            agentName: state.source.title,
            sessions: [session],
            isExpanded: isStackExpanded,
            isStandaloneSessionCard: true,
            standaloneStackSessionCount: stackSessionCount
        )
    }

    init(event: AgentEvent?) {
        guard let event else {
            self = .measurementPlaceholder
            return
        }
        id = "agent-\(event.source.rawValue)"
        source = event.source
        agentName = event.source.title
        sessions = [OverlaySessionContent(event: event)]
        isExpanded = true
        omittedSessionCount = 0
        isStandaloneSessionCard = false
        standaloneStackSessionCount = 0
    }

    private static func isMoreRecentlyActivated(
        _ left: EnumeratedSequence<[ActiveAgentState]>.Element,
        _ right: EnumeratedSequence<[ActiveAgentState]>.Element
    ) -> Bool {
        if let leftTime = left.element.sessionActivatedAt,
           let rightTime = right.element.sessionActivatedAt,
           leftTime != rightTime
        {
            return leftTime > rightTime
        }
        // PetCore has already projected a stable first-seen order for legacy
        // sessions without an activation timestamp. Preserve that order and
        // do not let a later Waiting/Failed status edge promote an old session.
        return left.offset < right.offset
    }
}

struct OverlayBubbleAccessibilityModel: Equatable {
    var sessionActionLabels: [String?]
    var sessionCloseActionLabels: [String?]
    var closeActionLabel: String?
    var closeActionHint: String?
    var groupActionLabel: String?

    init(content: OverlayBubbleContent, locale: String? = nil) {
        sessionActionLabels = content.visibleSessions.map { session in
            guard session.canOpen else { return nil }
            guard session.source != nil else {
                return Self.text(.overlayActionOpen, locale: locale)
            }
            return session.actionLabel(
                locale: locale ?? APCLocalization.interfaceLocaleIdentifier
            )
        }
        sessionCloseActionLabels = content.visibleSessions.map { _ in
            content.canDismiss
                ? Self.text(.overlayDismissSession, locale: locale)
                : nil
        }
        closeActionLabel = content.canDismiss
            ? Self.text(.overlayCloseBubbleAccessibility, locale: locale)
            : nil
        closeActionHint = content.canDismiss
            ? Self.text(.overlayCloseBubbleHint, locale: locale)
            : nil
        groupActionLabel = content.hasMultipleSessions
            ? Self.format(
                content.isExpanded
                    ? .overlayCollapseSessionsFormat
                    : .overlayExpandSessionsFormat,
                content.disclosureSessionCount,
                locale: locale
            )
            : nil
    }

    private static func text(_ key: APCLocalizationKey, locale: String?) -> String {
        locale.map { APCLocalization.text(key, locale: $0) }
            ?? APCLocalization.text(key)
    }

    private static func format(
        _ key: APCLocalizationKey,
        _ count: Int,
        locale: String?
    ) -> String {
        locale.map { APCLocalization.format(key, locale: $0, count) }
            ?? APCLocalization.format(key, count)
    }
}
