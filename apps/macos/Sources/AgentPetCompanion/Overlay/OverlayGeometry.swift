import AppKit
import AgentPetCompanionCore
import Combine
import CoreGraphics
import Foundation
import QuartzCore

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
    static func bubbleStandaloneMetadataHeight(
        fontScale: BubbleFontScale = .standard
    ) -> CGFloat {
        max(
            bubbleHeaderAvatarWidth,
            ceil(lineHeight(for: OverlayBubbleTypography.measurementFont(
                .caption1,
                scale: fontScale
            ))),
            ceil(lineHeight(for: OverlayBubbleTypography.measurementFont(
                .caption2,
                scale: fontScale
            ))) + 2
        )
    }
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
            return ceil(
                bubbleSessionVerticalPadding * 2
                    + bubbleStandaloneMetadataHeight(fontScale: fontScale)
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
