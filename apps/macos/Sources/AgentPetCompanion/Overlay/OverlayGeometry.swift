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
            tickSource?.isPaused = true
            return
        }
        let delivery = delivery
        self.pending = nil
        self.delivery = nil
        tickSource?.isPaused = true
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

enum OverlayBubbleAnchorDirection: String, CaseIterable, Equatable, Sendable {
    case above
    case below
    case left
    case right
}

struct OverlayBubblePanelLayout: Equatable, Sendable {
    let frame: CGRect
    let direction: OverlayBubbleAnchorDirection
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

/// The display-link delivery path translates only the parent pet panel. Child
/// bubble/menu panels are reconciled by the lower-frequency committed layout,
/// never by every pointer/display tick.
enum OverlayDirectManipulationMovePlan {
    static func moves(
        parentFrame: CGRect,
        previousPetCenter: CGPoint,
        presentedPetCenter: CGPoint
    ) -> [OverlayInteractionWindowMove] {
        let targetFrame = parentFrame.offsetBy(
            dx: presentedPetCenter.x - previousPetCenter.x,
            dy: presentedPetCenter.y - previousPetCenter.y
        )
        guard targetFrame != parentFrame else { return [] }
        return [OverlayInteractionWindowMove(
            role: .parentPetPanel,
            frame: targetFrame
        )]
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
        knownReopenIDs: Set<String>
    ) -> Set<String> {
        Set(activeSessions.compactMap { state -> String? in
            guard !knownReopenIDs.contains(OverlaySessionContent.reopenID(for: state)) else {
                return nil
            }
            return OverlaySessionContent.stableID(
                source: state.source,
                sessionID: state.sessionID ?? state.event.sessionID,
                anonymousSessionAlias: state.anonymousSessionAlias,
                fallbackEventID: state.event.id
            )
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
    static let bubbleCornerRadius: CGFloat = 14
    static let bubbleLeadingPadding: CGFloat = 8
    static let bubbleTrailingPadding: CGFloat = 8
    static let bubbleVerticalPadding: CGFloat = 7
    static var bubbleGroupHeaderHeight: CGFloat {
        max(
            17,
            ceil(lineHeight(for: NSFont.preferredFont(forTextStyle: .caption1))) + 2
        )
    }
    static let bubbleGroupHeaderSpacing: CGFloat = 4
    static let bubbleGroupToggleWidth: CGFloat = 44
    static let bubbleSessionHorizontalPadding: CGFloat = 8
    static let bubbleSessionVerticalPadding: CGFloat = 5
    static let bubbleSessionTitleSpacing: CGFloat = 2
    static let bubbleDetailLineLimit = 2
    static let bubbleSessionDividerHeight: CGFloat = 1
    static let bubbleHeaderAvatarWidth: CGFloat = 14
    static var bubbleHeaderButtonSize: CGFloat {
        max(15, bubbleGroupHeaderHeight - 2)
    }
    static let bubbleHeaderGap: CGFloat = 5
    static let bubbleCollapsedStackDepth: CGFloat = 8
    static let bubbleCollapsedStackLayerCount = 2
    static let bubbleCollapsedStackLayerOffset: CGFloat = 4
    static let bubbleCollapsedStackLayerInset: CGFloat = 5
    static let menuVisualSize = CGSize(width: 24, height: 24)
    static let menuHitSize = CGSize(width: 38, height: 38)
    static let pointerNearMargin: CGFloat = 12
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
        content: OverlayBubbleContent = .measurementPlaceholder
    ) -> CGSize {
        let availableWidth = max(96, size.width - 32)
        let maximumWidth = min(bubbleAdaptiveMaximumWidth, availableWidth)
        let width = maximumWidth < bubbleAdaptiveMinimumWidth
            ? maximumWidth
            : min(bubbleWidth, maximumWidth)
        let measuredHeight = measuredBubbleHeight(width: width, content: content)
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
        contents: [OverlayBubbleContent]
    ) -> [CGSize] {
        contents.map { resolvedBubbleSize(in: size, content: $0) }
    }

    static func resolvedBubbleStackSize(
        in size: CGSize,
        contents: [OverlayBubbleContent]
    ) -> CGSize {
        let bubbleSizes = resolvedBubbleSizes(in: size, contents: contents)
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
        alignLeft: Bool
    ) -> [CGRect] {
        let bubbleSizes = resolvedBubbleSizes(in: visibleFrameSize, contents: contents)
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

    static func bubbleCloseHitRect(in bubbleRect: CGRect) -> CGRect {
        let headerHitHeight = bubbleVerticalPadding
            + bubbleGroupHeaderHeight
            + bubbleGroupHeaderSpacing
        let headerTrailingControlWidth = bubbleTrailingPadding
            + bubbleHeaderButtonSize
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
        content: OverlayBubbleContent
    ) -> CGRect {
        guard content.hasMultipleSessions else { return .zero }
        let closeRect = bubbleCloseHitRect(in: bubbleRect)
        return CGRect(
            x: closeRect.minX - bubbleGroupToggleWidth,
            y: bubbleRect.minY,
            width: bubbleGroupToggleWidth,
            height: closeRect.height
        )
    }

    static func bubbleSessionRects(
        in bubbleRect: CGRect,
        content: OverlayBubbleContent
    ) -> [CGRect] {
        let innerWidth = max(0, bubbleRect.width - bubbleLeadingPadding - bubbleTrailingPadding)
        let rowHeights = bubbleSessionRowHeights(bubbleWidth: bubbleRect.width, content: content)
        var y = bubbleRect.minY + bubbleVerticalPadding
            + bubbleGroupHeaderHeight + bubbleGroupHeaderSpacing
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
        content: OverlayBubbleContent
    ) -> [CGFloat] {
        content.visibleSessions.map { session in
            measuredSessionRowHeight(width: bubbleWidth, session: session)
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
            previousDirection: nil
        ).center
    }

    static func bubblePlacement(
        bubbleSize: CGSize,
        displayWidthPt: CGFloat,
        petScreenCenter: CGPoint,
        screenFrame: CGRect,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil,
        previousDirection: OverlayBubbleAnchorDirection?
    ) -> (center: CGPoint, direction: OverlayBubbleAnchorDirection) {
        let petSize = petVisibleSize(displayWidthPt: displayWidthPt)
        let verticalOffsets = petVisualVerticalOffsets(
            displayWidthPt: displayWidthPt,
            envelope: petVisualEnvelope
        )
        let petLeft = petScreenCenter.x - petSize.width / 2
        let petRight = petScreenCenter.x + petSize.width / 2
        let petTop = petScreenCenter.y + verticalOffsets.top
        let petBottom = petScreenCenter.y + verticalOffsets.bottom

        let alignLeft = screenFrame.isEmpty
            ? false
            : petScreenCenter.x < screenFrame.midX
        let attachedX = alignLeft
            ? petLeft + bubbleSize.width / 2
            : petRight - bubbleSize.width / 2
        let candidates: [(OverlayBubbleAnchorDirection, CGPoint)] = [
            (.above, CGPoint(
                x: attachedX,
                y: petTop + bubbleGap + bubbleSize.height / 2
            )),
            (.below, CGPoint(
                x: attachedX,
                y: petBottom - bubbleGap - bubbleSize.height / 2
            )),
            (.left, CGPoint(
                x: petLeft - bubbleGap - bubbleSize.width / 2,
                y: petScreenCenter.y
            )),
            (.right, CGPoint(
                x: petRight + bubbleGap + bubbleSize.width / 2,
                y: petScreenCenter.y
            )),
        ]
        guard !screenFrame.isEmpty else {
            return (candidates[0].1, candidates[0].0)
        }
        let safeFrame = screenFrame.insetBy(dx: 8, dy: 8)
        func candidateRect(_ center: CGPoint) -> CGRect {
            rect(center: center, size: bubbleSize)
        }
        if let previousDirection,
           let previous = candidates.first(where: {
               $0.0 == previousDirection
                   && safeFrame.contains(candidateRect($0.1))
           }) {
            return (previous.1, previous.0)
        }
        let selected = candidates.enumerated().max { lhs, rhs in
            let lhsRect = candidateRect(lhs.element.1)
            let rhsRect = candidateRect(rhs.element.1)
            let lhsIntersection = lhsRect.intersection(safeFrame)
            let rhsIntersection = rhsRect.intersection(safeFrame)
            let lhsArea = lhsIntersection.isNull
                ? 0
                : lhsIntersection.width * lhsIntersection.height
            let rhsArea = rhsIntersection.isNull
                ? 0
                : rhsIntersection.width * rhsIntersection.height
            if lhsArea != rhsArea { return lhsArea < rhsArea }
            let lhsClamped = clampedBubbleCenter(
                lhs.element.1,
                bubbleSize: bubbleSize,
                safeFrame: safeFrame
            )
            let rhsClamped = clampedBubbleCenter(
                rhs.element.1,
                bubbleSize: bubbleSize,
                safeFrame: safeFrame
            )
            let lhsDistance = hypot(
                lhsClamped.x - lhs.element.1.x,
                lhsClamped.y - lhs.element.1.y
            )
            let rhsDistance = hypot(
                rhsClamped.x - rhs.element.1.x,
                rhsClamped.y - rhs.element.1.y
            )
            if lhsDistance != rhsDistance {
                return lhsDistance > rhsDistance
            }
            return lhs.offset > rhs.offset
        }?.element ?? candidates[0]
        return (
            clampedBubbleCenter(
                selected.1,
                bubbleSize: bubbleSize,
                safeFrame: safeFrame
            ),
            selected.0
        )
    }

    private static func clampedBubbleCenter(
        _ center: CGPoint,
        bubbleSize: CGSize,
        safeFrame: CGRect
    ) -> CGPoint {
        CGPoint(
            x: clamp(
                center.x,
                lower: safeFrame.minX + bubbleSize.width / 2,
                upper: safeFrame.maxX - bubbleSize.width / 2
            ),
            y: clamp(
                center.y,
                lower: safeFrame.minY + bubbleSize.height / 2,
                upper: safeFrame.maxY - bubbleSize.height / 2
            )
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

    static func pointerNearPetScreenRect(
        displayWidthPt: CGFloat,
        petScreenCenter: CGPoint,
        clickMenuEnabled: Bool,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> CGRect {
        var rects = [
            petVisualScreenRect(
                displayWidthPt: displayWidthPt,
                petScreenCenter: petScreenCenter,
                petVisualEnvelope: petVisualEnvelope
            ),
            rect(
                center: petScreenCenter,
                size: petDragSize(displayWidthPt: displayWidthPt)
            )
        ]

        if clickMenuEnabled {
            rects.append(rect(
                center: menuScreenCenter(
                    petScreenCenter: petScreenCenter,
                    displayWidthPt: displayWidthPt,
                    petVisualEnvelope: petVisualEnvelope
                ),
                size: menuHitSize
            ))
        }

        let union = rects.dropFirst().reduce(rects[0]) { partial, rect in
            partial.union(rect)
        }
        return union.insetBy(dx: -pointerNearMargin, dy: -pointerNearMargin)
    }

    /// The compact controls use a tighter visual hover region than the broad
    /// activation rectangle above. The activation rectangle deliberately
    /// includes a margin and the empty corridor between windows so a first
    /// click cannot fall through; using it for opacity would leave the compact
    /// control visible after the pointer has left the actual pet/control
    /// surfaces.
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
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> CGRect {
        bubblePanelScreenFrame(
            displayWidthPt: displayWidthPt,
            petScreenCenter: petScreenCenter,
            visibleFrame: visibleFrame,
            contents: [content],
            petVisualEnvelope: petVisualEnvelope
        )
    }

    static func bubblePanelScreenFrame(
        displayWidthPt: CGFloat,
        petScreenCenter: CGPoint,
        visibleFrame: CGRect,
        contents: [OverlayBubbleContent],
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> CGRect {
        bubblePanelLayout(
            displayWidthPt: displayWidthPt,
            petScreenCenter: petScreenCenter,
            visibleFrame: visibleFrame,
            contents: contents,
            petVisualEnvelope: petVisualEnvelope,
            previousDirection: nil
        ).frame
    }

    static func bubblePanelLayout(
        displayWidthPt: CGFloat,
        petScreenCenter: CGPoint,
        visibleFrame: CGRect,
        contents: [OverlayBubbleContent],
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil,
        previousDirection: OverlayBubbleAnchorDirection?
    ) -> OverlayBubblePanelLayout {
        let bubbleSize = resolvedBubbleStackSize(in: visibleFrame.size, contents: contents)
        guard bubbleSize.width > 0, bubbleSize.height > 0 else {
            return OverlayBubblePanelLayout(
                frame: .zero,
                direction: previousDirection ?? .above
            )
        }
        let placement = bubblePlacement(
            bubbleSize: bubbleSize,
            displayWidthPt: displayWidthPt,
            petScreenCenter: petScreenCenter,
            screenFrame: visibleFrame,
            petVisualEnvelope: petVisualEnvelope,
            previousDirection: previousDirection
        )
        return OverlayBubblePanelLayout(
            frame: rect(
                center: placement.center,
                size: bubbleSize
            ).integral,
            direction: placement.direction
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
        mousePassthroughEnabled: Bool = true,
        petFrameHitTest: OverlayPetFrameHitTest? = nil,
        overlayVisible: Bool = true,
        primaryButtonDown: Bool = false,
        activeInteractionID: UUID? = nil,
        maskState: OverlayPointerMaskState? = nil
    ) -> Bool {
        guard overlayVisible else { return false }
        if !mousePassthroughEnabled { return true }

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

    private static func measuredBubbleHeight(width: CGFloat, content: OverlayBubbleContent) -> CGFloat {
        let rowHeights = bubbleSessionRowHeights(bubbleWidth: width, content: content)
        let dividers = CGFloat(max(0, rowHeights.count - 1)) * bubbleSessionDividerHeight
        return ceil(
            bubbleVerticalPadding * 2
                + bubbleGroupHeaderHeight
                + bubbleGroupHeaderSpacing
                + rowHeights.reduce(0, +)
                + dividers
                + content.stackDecorationDepth
        )
    }

    private static func measuredSessionRowHeight(
        width _: CGFloat,
        session _: OverlaySessionContent
    ) -> CGFloat {
        let titleHeight = lineHeight(
            for: NSFont.preferredFont(forTextStyle: .callout)
        )
        let detailFont = NSFont.preferredFont(forTextStyle: .caption1)
        let detailLineHeight = lineHeight(for: detailFont)
        // Reserve the full two-line detail region. Tool activity often changes
        // between one and two lines; allowing that to resize an NSPanel on
        // every hook makes the whole bubble stack visibly jump.
        let detailHeight = detailLineHeight * CGFloat(bubbleDetailLineLimit)
        return ceil(
            bubbleSessionVerticalPadding * 2
                + titleHeight
                + bubbleSessionTitleSpacing
                + detailHeight
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
    case needsInput = 2
    case failed = 3

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

    private static func normalizedText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(
                of: "[\\s\\p{P}]+",
                with: "",
                options: .regularExpression
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

struct OverlayBubbleContent: Equatable, Identifiable {
    var id: String
    var source: AgentSource?
    var agentName: String
    var sessions: [OverlaySessionContent]
    var isExpanded: Bool
    var omittedSessionCount: Int

    var eventIDs: [String] { sessions.map(\.eventID) }
    var dismissalIDs: [String] { canDismiss ? sessions.map(\.id) : [] }
    var visibleSessions: [OverlaySessionContent] {
        guard !sessions.isEmpty, !isOmittedSummary else { return sessions }
        if !isExpanded {
            return [
                sessions.first(where: \.needsUserAttention) ?? sessions[0]
            ]
        }

        var ordered = [sessions[0]]
        let prioritized = sessions.dropFirst().filter(\.needsUserAttention)
            + sessions.dropFirst().filter { !$0.needsUserAttention }
        for session in prioritized {
            guard !ordered.contains(where: { $0.id == session.id }) else {
                continue
            }
            ordered.append(session)
        }
        return ordered
    }
    var sessionCount: Int { sessions.count }
    var representedSessionCount: Int {
        omittedSessionCount > 0 ? omittedSessionCount : sessionCount
    }
    var isOmittedSummary: Bool { omittedSessionCount > 0 }
    var canDismiss: Bool { !isOmittedSummary }
    var hasMultipleSessions: Bool { sessions.count > 1 }
    var isStacked: Bool { hasMultipleSessions && !isExpanded }
    var stackDecorationDepth: CGFloat {
        isStacked ? OverlayGeometry.bubbleCollapsedStackDepth : 0
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
        omittedSessionCount: 0
    )

    static func omittedSummary(count: Int) -> OverlayBubbleContent {
        OverlayBubbleContent(
            id: "omitted-session-summary",
            source: nil,
            agentName: "Agent Pet Companion",
            sessions: [.omittedSummary(count: count)],
            isExpanded: true,
            omittedSessionCount: count
        )
    }

    init(
        id: String,
        source: AgentSource?,
        agentName: String,
        sessions: [OverlaySessionContent],
        isExpanded: Bool = true,
        omittedSessionCount: Int = 0
    ) {
        self.id = id
        self.source = source
        self.agentName = agentName
        self.sessions = sessions
        self.isExpanded = isExpanded
        self.omittedSessionCount = omittedSessionCount
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
    }

    init(state: ActiveAgentState) {
        self.init(source: state.source, states: [state])
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
                content.sessionCount,
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
