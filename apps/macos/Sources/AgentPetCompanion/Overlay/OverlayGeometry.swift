import AppKit
import AgentPetCompanionCore
import Combine
import CoreGraphics
import Foundation

struct OverlayDisplayGeometry: Equatable, Sendable {
    var frame: CGRect
    var visibleFrame: CGRect
    var backingScaleFactor: CGFloat
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
/// draws without comparing the mask payload at 10/20 FPS.
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
            let activation = nonEmpty(state.sessionActivatedAt)
                ?? event.id
            return scopedEntryID(
                event: event,
                sessionID: state.sessionID ?? event.sessionID,
                marker: activation
            )
        case .done:
            let completion = nonEmpty(state.sessionActivatedAt)
                ?? event.id
            return scopedEntryID(
                event: event,
                sessionID: state.sessionID ?? event.sessionID,
                marker: completion
            )
        case .tool, .waiting, .review, .failed:
            return event.eventType.rawValue
        }
    }

    private static func scopedEntryID(
        event: AgentEvent,
        sessionID: String?,
        marker: String
    ) -> String {
        [
            event.eventType.rawValue,
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

enum OverlayScaleFeedbackVisibility {
    static func isVisible(
        isFocused _: Bool,
        isResizing: Bool,
        isStepFeedbackVisible: Bool
    ) -> Bool {
        isResizing || isStepFeedbackVisible
    }
}

enum OverlayControlVisibility {
    static let hoverShowDelay = Duration.zero
    static let hoverHideDelay = Duration.milliseconds(300)

    static func isVisible(
        pointerNearPet: Bool,
        petDragInProgress: Bool,
        resizeInProgress: Bool,
        keyboardFocusActive: Bool = false
    ) -> Bool {
        pointerNearPet || petDragInProgress || resizeInProgress || keyboardFocusActive
    }

    static func transitionDelay(showing: Bool, forced: Bool) -> Duration {
        forced ? .zero : (showing ? hoverShowDelay : hoverHideDelay)
    }
}

/// Motion values shared by SwiftUI content and the AppKit overlay panels.
enum OverlayMotion {
    static let controlFadeDuration: TimeInterval = 0.14
    static let controlFadeDelay = Duration.milliseconds(140)
    static let bubbleLayoutDuration: TimeInterval = 0.20
    static let bubbleLayoutDelay = Duration.milliseconds(200)
    static let reducedMotionCrossfadeDuration: TimeInterval = 0.16
    static let reducedMotionCrossfadeDelay = Duration.milliseconds(160)
    static let reducedMotionCrossfadeHalfDelay = Duration.milliseconds(80)
}

/// One presentation state coordinates every transient overlay control. Pointer
/// hover begins the visual fade immediately, while pointer exit is delayed to
/// avoid flicker between the pet and its controls. Keyboard focus and active
/// drag/resize interactions remain immediate.
@MainActor
final class OverlayControlPresentationState: ObservableObject {
    typealias TransitionSleeper = @MainActor @Sendable (Duration) async throws -> Void

    enum Region: Hashable {
        case pet
        case bubble
        case menu
        case resize
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

enum OverlayPetPointerGesture {
    static let dragThreshold: CGFloat = 3

    static func exceedsDragThreshold(from start: CGPoint, to current: CGPoint) -> Bool {
        hypot(current.x - start.x, current.y - start.y) > dragThreshold
    }
}

enum OverlayPetActivationDestination: Equatable {
    case session(OverlaySessionContent)
    case bubble
    case controlCenter

    static func resolve(
        activeState: ActiveAgentState?,
        bubbleDismissed: Bool,
        hasAvailableBubbleContent: Bool
    ) -> OverlayPetActivationDestination {
        resolve(
            activeSession: activeState.map(OverlaySessionContent.init(state:)),
            bubbleDismissed: bubbleDismissed,
            hasAvailableBubbleContent: hasAvailableBubbleContent
        )
    }

    static func resolve(
        activeSession: OverlaySessionContent?,
        bubbleDismissed _: Bool,
        hasAvailableBubbleContent: Bool
    ) -> OverlayPetActivationDestination {
        if let activeSession {
            if activeSession.canOpen {
                return .session(activeSession)
            }
            if hasAvailableBubbleContent {
                return .bubble
            }
        }
        return .controlCenter
    }
}

enum OverlayPresentedAgentState {
    static func resolve(
        canonicalState: ActiveAgentState?,
        activeSessions: [ActiveAgentState],
        dismissedSessionIDs: Set<String>
    ) -> ActiveAgentState? {
        if let visible = activeSessions.first(where: {
            !isDismissed($0, dismissedSessionIDs: dismissedSessionIDs)
        }) {
            return visible
        }
        guard let canonicalState,
              !isDismissed(canonicalState, dismissedSessionIDs: dismissedSessionIDs)
        else {
            return nil
        }
        return canonicalState
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
    static let minimumScale: CGFloat = 0.10
    static let maximumScale: CGFloat = 1.8
    static let defaultScale: CGFloat = 0.72
    static let resizeStep: CGFloat = 0.05
    static let bubbleWidth: CGFloat = 344
    static let bubbleMinimumHeight: CGFloat = 70
    static let bubbleMaximumHeight: CGFloat = 680
    static let bubbleGap: CGFloat = 3
    static let bubbleMinimumWidth: CGFloat = 108
    static let bubbleStackSpacing: CGFloat = 4
    static let bubbleCornerRadius: CGFloat = 14
    static let bubbleLeadingPadding: CGFloat = 8
    static let bubbleTrailingPadding: CGFloat = 8
    static let bubbleVerticalPadding: CGFloat = 7
    static let bubbleGroupHeaderHeight: CGFloat = 17
    static let bubbleGroupHeaderSpacing: CGFloat = 4
    static let bubbleGroupToggleWidth: CGFloat = 44
    static let bubbleSessionHorizontalPadding: CGFloat = 8
    static let bubbleSessionVerticalPadding: CGFloat = 5
    static let bubbleSessionTitleFontSize: CGFloat = 11.4
    static let bubbleSessionTitleSpacing: CGFloat = 2
    static let bubbleSessionActionSpacing: CGFloat = 3
    static let bubbleSessionActionFontSize: CGFloat = 10
    static let bubbleDetailLineLimit = 2
    static let bubbleSessionDividerHeight: CGFloat = 1
    static let bubbleHeaderAvatarWidth: CGFloat = 14
    static let bubbleHeaderButtonSize: CGFloat = 15
    static let bubbleHeaderGap: CGFloat = 5
    static let bubbleHeaderFontSize: CGFloat = 11.2
    static let bubbleDetailFontSize: CGFloat = 11.8
    static let bubbleCollapsedStackDepth: CGFloat = 8
    static let bubbleCollapsedStackLayerCount = 2
    static let bubbleCollapsedStackLayerOffset: CGFloat = 4
    static let bubbleCollapsedStackLayerInset: CGFloat = 5
    static let menuVisualSize = CGSize(width: 24, height: 24)
    static let menuHitSize = CGSize(width: 38, height: 38)
    static let resizeVisualSize = CGSize(width: 24, height: 24)
    static let resizeHitSize = CGSize(width: 38, height: 38)
    static let pointerNearMargin: CGFloat = 12
    static let controlVisibilitySlop: CGFloat = 4
    private static let petStageBaseSize = CGSize(width: 238, height: 318)
    private static let petSpriteBaseSize = CGSize(width: 230, height: 310)
    private static let petShadowRadius: CGFloat = 10
    private static let petShadowYOffset: CGFloat = 6
    private static let panelContentPadding: CGFloat = 2
    private static let petControlTrailingGap: CGFloat = 8
    private static let petMenuToPetGap: CGFloat = 3
    private static let resizeSideVerticalRatio: CGFloat = 0.28
    private static let petControlMinimumVerticalGap: CGFloat = 2

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
        let maximumWidth = min(bubbleWidth, availableWidth)
        let minimumWidth = min(bubbleMinimumWidth, maximumWidth)
        let width = max(minimumWidth, maximumWidth)
        let measuredHeight = measuredBubbleHeight(width: width, content: content)
        return CGSize(
            width: width,
            height: min(bubbleMaximumHeight, max(bubbleMinimumHeight, measuredHeight))
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

    static func defaultPetScreenCenter(in visibleFrame: CGRect, scale: CGFloat) -> CGPoint {
        let petSize = petVisibleSize(scale: scale)
        return clampedPetScreenCenter(
            CGPoint(
                x: visibleFrame.maxX - petSize.width * 0.72,
                y: visibleFrame.minY + petSize.height * 0.62
            ),
            scale: scale,
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
        scale: CGFloat,
        visibleFrame: CGRect,
        clickMenuEnabled: Bool = true,
        includeResize: Bool = true,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> CGPoint {
        guard !visibleFrame.isEmpty else { return proposedCenter }

        let relativeBounds = petMovementScreenBounds(
            scale: scale,
            petScreenCenter: .zero,
            clickMenuEnabled: clickMenuEnabled,
            includeResize: includeResize,
            petVisualEnvelope: petVisualEnvelope
        )
        let edgeInset: CGFloat = 1
        let minX = visibleFrame.minX - relativeBounds.minX + edgeInset
        let maxX = visibleFrame.maxX - relativeBounds.maxX - edgeInset
        let minY = visibleFrame.minY - relativeBounds.minY + edgeInset
        let maxY = visibleFrame.maxY - relativeBounds.maxY - edgeInset

        return CGPoint(
            x: clamp(proposedCenter.x, lower: minX, upper: maxX),
            y: clamp(proposedCenter.y, lower: minY, upper: maxY)
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
        scale: CGFloat,
        petCenter: CGPoint,
        panelFrame: CGRect,
        screenFrame: CGRect,
        in size: CGSize
    ) -> CGPoint {
        let petScreenPoint = screenPoint(forLocalPoint: petCenter, panelFrame: panelFrame)
        let screenCenter = bubbleScreenCenter(
            bubbleSize: bubbleSize,
            scale: scale,
            petScreenCenter: petScreenPoint,
            screenFrame: screenFrame
        )
        return localPoint(forScreenPoint: screenCenter, panelFrame: panelFrame, fallbackIn: size)
    }

    static func bubbleScreenCenter(
        bubbleSize: CGSize,
        scale: CGFloat,
        petScreenCenter: CGPoint,
        screenFrame: CGRect,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> CGPoint {
        let petSize = petVisibleSize(scale: scale)
        let verticalOffsets = petVisualVerticalOffsets(
            scale: scale,
            envelope: petVisualEnvelope
        )
        let petLeft = petScreenCenter.x - petSize.width / 2
        let petRight = petScreenCenter.x + petSize.width / 2
        let petTop = petScreenCenter.y + verticalOffsets.top
        let petBottom = petScreenCenter.y + verticalOffsets.bottom

        let alignLeft = screenFrame.isEmpty ? false : petScreenCenter.x < screenFrame.midX
        let aboveCenter = petTop + bubbleGap + bubbleSize.height / 2
        let belowCenter = petBottom - bubbleGap - bubbleSize.height / 2
        let hasSpaceAbove = screenFrame.isEmpty || aboveCenter <= screenFrame.maxY - 8
        let hasSpaceBelow = screenFrame.isEmpty || belowCenter >= screenFrame.minY + 8
        // The bubble is visually attached to the pet's top edge. Only fall
        // below when the top side genuinely cannot fit and the bottom can.
        let placeBelow = !hasSpaceAbove && hasSpaceBelow

        let unclampedX = alignLeft
            ? petLeft + bubbleSize.width / 2
            : petRight - bubbleSize.width / 2

        let unclampedY = placeBelow
            ? petBottom - bubbleGap - bubbleSize.height / 2
            : petTop + bubbleGap + bubbleSize.height / 2

        guard !screenFrame.isEmpty else {
            return CGPoint(x: unclampedX, y: unclampedY)
        }

        return CGPoint(
            x: clamp(
                unclampedX,
                lower: screenFrame.minX + bubbleSize.width / 2 + 8,
                upper: screenFrame.maxX - bubbleSize.width / 2 - 8
            ),
            y: clamp(
                unclampedY,
                lower: screenFrame.minY + bubbleSize.height / 2 + 8,
                upper: screenFrame.maxY - bubbleSize.height / 2 - 8
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

    static func petDragSize(scale: CGFloat) -> CGSize {
        let visible = petVisibleSize(scale: scale)
        return CGSize(
            width: max(26, visible.width * 0.78),
            height: max(38, visible.height * 0.90)
        )
    }

    static func petVisibleSize(scale: CGFloat) -> CGSize {
        CGSize(width: max(30, 230 * scale), height: max(42, 310 * scale))
    }

    static func petVisualVerticalOffsets(
        scale: CGFloat,
        envelope: OverlayPetVisualEnvelope?
    ) -> (bottom: CGFloat, top: CGFloat) {
        let bounds = fittedPetVisualBounds(scale: scale, envelope: envelope)
        return (bounds.minY, bounds.maxY)
    }

    static func petVisualHorizontalOffsets(
        scale: CGFloat,
        envelope: OverlayPetVisualEnvelope?
    ) -> (left: CGFloat, right: CGFloat) {
        let bounds = fittedPetVisualBounds(scale: scale, envelope: envelope)
        return (bounds.minX, bounds.maxX)
    }

    private static func fittedPetVisualBounds(
        scale: CGFloat,
        envelope: OverlayPetVisualEnvelope?
    ) -> CGRect {
        let spriteSize = CGSize(
            width: petSpriteBaseSize.width * scale,
            height: petSpriteBaseSize.height * scale
        )
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

    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(maximumScale, max(minimumScale, scale))
    }

    static func resolvedInitialScale(
        persistedScale: CGFloat,
        hasPersistedPosition: Bool
    ) -> CGFloat {
        guard hasPersistedPosition, persistedScale.isFinite, persistedScale > 0 else {
            return defaultScale
        }
        return clampedScale(persistedScale)
    }

    static func resizeCenter(
        petCenter: CGPoint,
        scale: CGFloat,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> CGPoint {
        let petSize = petVisibleSize(scale: scale)
        let petRight = petVisualHorizontalOffsets(
            scale: scale,
            envelope: petVisualEnvelope
        ).right
        let verticalOffset = resizeVerticalOffset(
            petHeight: petSize.height,
            menuCenterOffset: menuLocalVerticalOffset(
                scale: scale,
                envelope: petVisualEnvelope
            )
        )
        return CGPoint(
            x: petCenter.x + petRight + petControlTrailingGap,
            y: petCenter.y + verticalOffset
        )
    }

    static func resizeScreenCenter(
        petScreenCenter: CGPoint,
        scale: CGFloat,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> CGPoint {
        let petSize = petVisibleSize(scale: scale)
        let petRight = petVisualHorizontalOffsets(
            scale: scale,
            envelope: petVisualEnvelope
        ).right
        let verticalOffset = resizeVerticalOffset(
            petHeight: petSize.height,
            menuCenterOffset: menuLocalVerticalOffset(
                scale: scale,
                envelope: petVisualEnvelope
            )
        )
        return CGPoint(
            x: petScreenCenter.x + petRight + petControlTrailingGap,
            y: petScreenCenter.y - verticalOffset
        )
    }

    static func menuCenter(
        petCenter: CGPoint,
        scale: CGFloat,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> CGPoint {
        let petRight = petVisualHorizontalOffsets(
            scale: scale,
            envelope: petVisualEnvelope
        ).right
        return CGPoint(
            x: petCenter.x + petRight + petControlTrailingGap,
            y: petCenter.y + menuLocalVerticalOffset(
                scale: scale,
                envelope: petVisualEnvelope
            )
        )
    }

    static func menuScreenCenter(
        petScreenCenter: CGPoint,
        scale: CGFloat,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> CGPoint {
        let petRight = petVisualHorizontalOffsets(
            scale: scale,
            envelope: petVisualEnvelope
        ).right
        return CGPoint(
            x: petScreenCenter.x + petRight + petControlTrailingGap,
            y: petScreenCenter.y - menuLocalVerticalOffset(
                scale: scale,
                envelope: petVisualEnvelope
            )
        )
    }

    private static func menuLocalVerticalOffset(
        scale: CGFloat,
        envelope: OverlayPetVisualEnvelope?
    ) -> CGFloat {
        let petTop = petVisualVerticalOffsets(scale: scale, envelope: envelope).top
        return -petTop + menuHitSize.height / 2 + petMenuToPetGap
    }

    private static func resizeVerticalOffset(
        petHeight: CGFloat,
        menuCenterOffset: CGFloat
    ) -> CGFloat {
        let preferredOffset = petHeight * resizeSideVerticalRatio
        let minimumCenterSeparation = (menuHitSize.height + resizeHitSize.height) / 2
            + petControlMinimumVerticalGap
        return max(preferredOffset, menuCenterOffset + minimumCenterSeparation)
    }

    static func petPanelScreenFrame(
        scale: CGFloat,
        petScreenCenter: CGPoint,
        clickMenuEnabled: Bool,
        includeResize: Bool
    ) -> CGRect {
        petInteractiveScreenBounds(
            scale: scale,
            petScreenCenter: petScreenCenter,
            clickMenuEnabled: clickMenuEnabled,
            includeResize: includeResize
        ).integral
    }

    static func petInteractiveScreenBounds(
        scale: CGFloat,
        petScreenCenter: CGPoint,
        clickMenuEnabled: Bool,
        includeResize: Bool
    ) -> CGRect {
        let visibleSize = petVisibleSize(scale: scale)
        let stageSize = CGSize(
            width: max(visibleSize.width, petStageBaseSize.width * scale),
            height: max(visibleSize.height, petStageBaseSize.height * scale)
        )
        let stage = rect(center: petScreenCenter, size: stageSize)
        var bounds = CGRect(
            x: stage.minX - petShadowRadius,
            y: stage.minY - petShadowRadius - petShadowYOffset,
            width: stage.width + petShadowRadius * 2,
            height: stage.height + petShadowRadius * 2
        )

        if includeResize {
            bounds = bounds.union(rect(
                center: resizeScreenCenter(petScreenCenter: petScreenCenter, scale: scale),
                size: resizeHitSize
            ))
        }

        if clickMenuEnabled {
            bounds = bounds.union(rect(
                center: menuScreenCenter(petScreenCenter: petScreenCenter, scale: scale),
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
        scale: CGFloat,
        petScreenCenter: CGPoint,
        clickMenuEnabled: Bool,
        includeResize: Bool,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> CGRect {
        var bounds = fittedPetVisualBounds(
            scale: scale,
            envelope: petVisualEnvelope
        )
        .offsetBy(dx: petScreenCenter.x, dy: petScreenCenter.y)
        .insetBy(dx: -panelContentPadding, dy: -panelContentPadding)

        if includeResize {
            bounds = bounds.union(rect(
                center: resizeScreenCenter(
                    petScreenCenter: petScreenCenter,
                    scale: scale,
                    petVisualEnvelope: petVisualEnvelope
                ),
                size: resizeHitSize
            ))
        }

        if clickMenuEnabled {
            bounds = bounds.union(rect(
                center: menuScreenCenter(
                    petScreenCenter: petScreenCenter,
                    scale: scale,
                    petVisualEnvelope: petVisualEnvelope
                ),
                size: menuHitSize
            ))
        }

        return bounds.insetBy(dx: -panelContentPadding, dy: -panelContentPadding)
    }

    static func pointerNearPetScreenRect(
        scale: CGFloat,
        petScreenCenter: CGPoint,
        clickMenuEnabled: Bool,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> CGRect {
        var rects = [
            petVisualScreenRect(
                scale: scale,
                petScreenCenter: petScreenCenter,
                petVisualEnvelope: petVisualEnvelope
            ),
            rect(center: petScreenCenter, size: petDragSize(scale: scale)),
            rect(
                center: resizeScreenCenter(
                    petScreenCenter: petScreenCenter,
                    scale: scale,
                    petVisualEnvelope: petVisualEnvelope
                ),
                size: resizeHitSize
            )
        ]

        if clickMenuEnabled {
            rects.append(rect(
                center: menuScreenCenter(
                    petScreenCenter: petScreenCenter,
                    scale: scale,
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
    /// click cannot fall through; using it for opacity would leave the resize
    /// affordance visible after the pointer has left the actual pet/control
    /// surfaces.
    static func shouldShowControls(
        at screenPoint: CGPoint,
        scale: CGFloat,
        petScreenCenter: CGPoint,
        clickMenuEnabled: Bool,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> Bool {
        var regions = [
            petVisualScreenRect(
                scale: scale,
                petScreenCenter: petScreenCenter,
                petVisualEnvelope: petVisualEnvelope
            ).insetBy(dx: -controlVisibilitySlop, dy: -controlVisibilitySlop),
            rect(
                center: resizeScreenCenter(
                    petScreenCenter: petScreenCenter,
                    scale: scale,
                    petVisualEnvelope: petVisualEnvelope
                ),
                size: resizeHitSize
            ).insetBy(dx: -controlVisibilitySlop, dy: -controlVisibilitySlop)
        ]

        if clickMenuEnabled {
            regions.append(rect(
                center: menuScreenCenter(
                    petScreenCenter: petScreenCenter,
                    scale: scale,
                    petVisualEnvelope: petVisualEnvelope
                ),
                size: menuHitSize
            ).insetBy(dx: -controlVisibilitySlop, dy: -controlVisibilitySlop))
        }

        return regions.contains { $0.contains(screenPoint) }
    }

    static func petVisualScreenRect(
        scale: CGFloat,
        petScreenCenter: CGPoint,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> CGRect {
        let horizontal = petVisualHorizontalOffsets(scale: scale, envelope: petVisualEnvelope)
        let vertical = petVisualVerticalOffsets(scale: scale, envelope: petVisualEnvelope)
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
        scale: CGFloat,
        petCenter: CGPoint,
        frameHitTest: OverlayPetFrameHitTest
    ) -> Bool {
        guard scale.isFinite, scale > 0,
              point.x.isFinite, point.y.isFinite,
              frameHitTest.canvasSize.width.isFinite,
              frameHitTest.canvasSize.height.isFinite,
              frameHitTest.canvasSize.width > 0,
              frameHitTest.canvasSize.height > 0 else {
            return false
        }

        let drawableSize = CGSize(
            width: petSpriteBaseSize.width * scale,
            height: petSpriteBaseSize.height * scale
        )
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
        scale: CGFloat,
        petScreenCenter: CGPoint,
        visibleFrame: CGRect,
        content: OverlayBubbleContent = .measurementPlaceholder,
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> CGRect {
        bubblePanelScreenFrame(
            scale: scale,
            petScreenCenter: petScreenCenter,
            visibleFrame: visibleFrame,
            contents: [content],
            petVisualEnvelope: petVisualEnvelope
        )
    }

    static func bubblePanelScreenFrame(
        scale: CGFloat,
        petScreenCenter: CGPoint,
        visibleFrame: CGRect,
        contents: [OverlayBubbleContent],
        petVisualEnvelope: OverlayPetVisualEnvelope? = nil
    ) -> CGRect {
        let bubbleSize = resolvedBubbleStackSize(in: visibleFrame.size, contents: contents)
        guard bubbleSize.width > 0, bubbleSize.height > 0 else { return .zero }
        return rect(
            center: bubbleScreenCenter(
                bubbleSize: bubbleSize,
                scale: scale,
                petScreenCenter: petScreenCenter,
                screenFrame: visibleFrame,
                petVisualEnvelope: petVisualEnvelope
            ),
            size: bubbleSize
        ).integral
    }

    static func panelScreenFrame(
        scale: CGFloat,
        petScreenCenter: CGPoint,
        bubbleVisible: Bool,
        clickMenuEnabled: Bool,
        visibleFrame: CGRect,
        bubbleContent: OverlayBubbleContent = .measurementPlaceholder
    ) -> CGRect {
        let bubbleSize = resolvedBubbleSize(in: visibleFrame.size, content: bubbleContent)
        var rects = [
            rect(center: petScreenCenter, size: petVisibleSize(scale: scale)),
            rect(center: resizeScreenCenter(petScreenCenter: petScreenCenter, scale: scale), size: resizeHitSize)
        ]

        if clickMenuEnabled {
            rects.append(rect(center: menuScreenCenter(petScreenCenter: petScreenCenter, scale: scale), size: menuHitSize))
        }

        if bubbleVisible {
            rects.append(rect(
                center: bubbleScreenCenter(
                    bubbleSize: bubbleSize,
                    scale: scale,
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
        scale: CGFloat,
        petCenter: CGPoint,
        bubbleVisible: Bool,
        clickMenuEnabled: Bool,
        panelFrame: CGRect,
        screenFrame: CGRect,
        includeBubble: Bool,
        includeResize: Bool = true,
        bubbleContent: OverlayBubbleContent = .measurementPlaceholder
    ) -> [CGRect] {
        let displayPetCenter = petCenter
        let menuCenter = menuCenter(petCenter: displayPetCenter, scale: scale)
        var rects: [CGRect] = [
            rect(center: displayPetCenter, size: petVisibleSize(scale: scale))
        ]

        if includeResize {
            rects.append(rect(center: resizeCenter(petCenter: displayPetCenter, scale: scale), size: resizeHitSize))
        }

        if clickMenuEnabled {
            rects.append(rect(center: menuCenter, size: menuHitSize))
        }

        if bubbleVisible && includeBubble {
            let bubbleSize = resolvedBubbleSize(in: screenFrame.size, content: bubbleContent)
            let center = bubblePosition(
                bubbleSize: bubbleSize,
                scale: scale,
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
        scale: CGFloat,
        petCenter: CGPoint,
        bubbleVisible: Bool,
        clickMenuEnabled: Bool,
        panelFrame: CGRect,
        screenFrame: CGRect,
        includeBubble: Bool,
        includeResize: Bool = true,
        bubbleContent: OverlayBubbleContent = .measurementPlaceholder,
        mousePassthroughEnabled: Bool = true,
        petFrameHitTest: OverlayPetFrameHitTest? = nil
    ) -> Bool {
        guard CGRect(origin: .zero, size: containerSize).contains(point) else {
            return false
        }
        guard mousePassthroughEnabled else { return true }

        let rects = interactiveRects(
            in: containerSize,
            scale: scale,
            petCenter: petCenter,
            bubbleVisible: bubbleVisible,
            clickMenuEnabled: clickMenuEnabled,
            panelFrame: panelFrame,
            screenFrame: screenFrame,
            includeBubble: includeBubble,
            includeResize: includeResize,
            bubbleContent: bubbleContent
        )
        guard let petDragRect = rects.first else { return false }

        // Resize, menu, and bubble surfaces keep their geometric hit regions.
        // Only the pet body is narrowed to the currently presented frame.
        if rects.dropFirst().contains(where: { $0.contains(point) }) {
            return true
        }
        guard petDragRect.contains(point) else {
            return false
        }
        guard let petFrameHitTest else {
            // Frame masks are published asynchronously and are intentionally
            // cleared during renderer/state transitions. Keep the visible pet
            // draggable until the next mask can refine transparent pixels.
            return true
        }
        return petFrameContainsOpaquePixel(
            atTopLeftPoint: point,
            scale: scale,
            petCenter: petCenter,
            frameHitTest: petFrameHitTest
        )
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
            for: .systemFont(ofSize: bubbleSessionTitleFontSize, weight: .semibold)
        )
        let detailFont = NSFont.systemFont(ofSize: bubbleDetailFontSize, weight: .medium)
        let detailLineHeight = lineHeight(for: detailFont)
        // Reserve the full two-line detail region. Tool activity often changes
        // between one and two lines; allowing that to resize an NSPanel on
        // every hook makes the whole bubble stack visibly jump.
        let detailHeight = detailLineHeight * CGFloat(bubbleDetailLineLimit)
        let actionHeight = lineHeight(
            for: .systemFont(ofSize: bubbleSessionActionFontSize, weight: .semibold)
        )
        return ceil(
            bubbleSessionVerticalPadding * 2
                + titleHeight
                + bubbleSessionTitleSpacing
                + detailHeight
                + bubbleSessionActionSpacing
                + actionHeight
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
        case .review, .done: .ready
        case .start, .tool, nil: .running
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

struct OverlaySessionContent: Equatable, Identifiable {
    var id: String
    var eventID: String
    var source: AgentSource?
    var sessionID: String?
    var eventType: AgentEventKind?
    var sessionTitle: String
    var messageText: String
    var statusText: String
    var navigation: AgentSessionNavigation

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
        guard let source else {
            return APCLocalization.text(.overlayActionOpen)
        }
        return APCLocalizedPresentation.navigationActionTitle(
            navigationCapability,
            source: source
        ) ?? APCLocalizedPresentation.navigationUnavailableTitle()
    }
    var accessibilityReadingOrder: [String] {
        [
            source?.title,
            sessionTitle,
            statusText,
            messageText,
            actionLabel,
        ]
        .compactMap(Self.compactMessage)
    }
    var accessibilityLabel: String {
        accessibilityReadingOrder.joined(separator: ", ")
    }
    var dismissesAfterActivation: Bool {
        switch eventType {
        case .review, .done: true
        case .start, .tool, .waiting, .failed, nil: false
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
        messageText: String,
        statusText: String,
        navigation: AgentSessionNavigation = AgentSessionNavigation()
    ) {
        self.id = id
        self.eventID = eventID ?? id
        self.source = source
        self.sessionID = sessionID
        self.eventType = eventType
        self.sessionTitle = sessionTitle
        self.messageText = messageText
        self.statusText = statusText
        self.navigation = navigation
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
        statusText = Self.displayStatus(for: event.eventType)
        let proposedTitle = Self.sessionTitle(for: state)
        sessionTitle = Self.normalizedText(proposedTitle) == Self.normalizedText(statusText)
            ? Self.genericSessionTitle(for: state)
            : proposedTitle
        navigation = state.overlayDisplay?.navigation ?? AgentSessionNavigation()
        messageText = Self.nonredundantMessage(
            Self.displayMessage(for: state),
            title: sessionTitle,
            status: statusText,
            eventType: event.eventType
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
        sessionTitle = APCLocalization.format(.overlaySessionTitleFormat, event.source.shortTitle)
        statusText = Self.displayStatus(for: event.eventType)
        navigation = event.sessionNavigation
        messageText = Self.nonredundantMessage(
            Self.fallbackDetail(for: event.eventType),
            title: sessionTitle,
            status: statusText,
            eventType: event.eventType
        )
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
        case .waiting, .review, .failed:
            return "attention:\(stableID):\(state.event.id)"
        case .start, .tool, .done:
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

    static func displayMessage(
        summaryKind: AgentOverlaySummaryKind?,
        eventType: AgentEventKind
    ) -> String {
        summaryMessage(for: summaryKind ?? fallbackSummaryKind(for: eventType))
    }

    private static func displayMessage(for state: ActiveAgentState) -> String {
        assistantMessage(for: state) ?? displayMessage(
            summaryKind: state.overlayDisplay?.summaryKind,
            eventType: state.event.eventType
        )
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
        status: String,
        eventType: AgentEventKind
    ) -> String {
        let occupied = Set([title, status].map(normalizedText))
        if !occupied.contains(normalizedText(proposed)) {
            return proposed
        }
        let fallback = fallbackDetail(for: eventType)
        return occupied.contains(normalizedText(fallback)) ? "" : fallback
    }

    private static func fallbackSummaryKind(
        for eventType: AgentEventKind
    ) -> AgentOverlaySummaryKind {
        switch eventType {
        case .start: .running
        case .tool: .tool
        case .waiting: .needsInput
        case .review: .review
        case .done: .done
        case .failed: .failed
        }
    }

    private static func summaryMessage(for kind: AgentOverlaySummaryKind) -> String {
        let key: APCLocalizationKey = switch kind {
        case .running: .overlayDetailRunning
        case .thinking: .overlayActivityThinking
        case .plan: .overlayActivityPlan
        case .command: .overlayActivityCommand
        case .file: .overlayActivityFile
        case .fileChange: .overlayActivityFileChange
        case .tool: .overlayActivityTool
        case .subagent: .overlayActivitySubagent
        case .search: .overlayActivitySearch
        case .network: .overlayActivityNetwork
        case .image: .overlayActivityImage
        case .compaction: .overlayActivityCompaction
        case .needsInput: .overlayDetailNeedsInput
        case .review: .overlayDetailReady
        case .done: .overlayDetailCompleted
        case .failed: .overlayDetailBlocked
        }
        return APCLocalization.text(key)
    }

    static func displayStatus(for eventType: AgentEventKind) -> String {
        APCLocalizedPresentation.lifecycleTitle(
            ProductLifecycleState(eventKind: eventType)
        )
    }

    private static func fallbackDetail(for eventType: AgentEventKind) -> String {
        switch eventType {
        case .start, .tool: APCLocalization.text(.overlayDetailRunning)
        case .waiting: APCLocalization.text(.overlayDetailNeedsInput)
        case .review: APCLocalization.text(.overlayDetailReady)
        case .done: APCLocalization.text(.overlayDetailCompleted)
        case .failed: APCLocalization.text(.overlayDetailBlocked)
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
        guard !isExpanded, sessions.count > 1 else { return sessions }
        let latest = sessions[0]
        let attention = sessions.dropFirst().filter {
            $0.eventType == .waiting || $0.eventType == .review || $0.eventType == .failed
        }
        return [latest] + attention
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
            guard let source = session.source else {
                return Self.text(.overlayActionOpen, locale: locale)
            }
            return APCLocalizedPresentation.navigationActionTitle(
                session.navigationCapability,
                source: source,
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
