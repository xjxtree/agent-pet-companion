import AppKit
import AgentPetCompanionCore
import CoreGraphics

struct OverlayDisplayGeometry: Equatable, Sendable {
    var frame: CGRect
    var visibleFrame: CGRect
    var backingScaleFactor: CGFloat
}

struct OverlayPetVisualEnvelope: Equatable, Sendable {
    var canvasSize: CGSize
    var visibleBounds: CGRect
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
    static let bubbleSessionHorizontalPadding: CGFloat = 8
    static let bubbleSessionVerticalPadding: CGFloat = 5
    static let bubbleSessionTitleFontSize: CGFloat = 11.4
    static let bubbleSessionTitleSpacing: CGFloat = 2
    static let bubbleDetailLineLimit = 2
    static let bubbleSessionDividerHeight: CGFloat = 1
    static let bubbleHeaderAvatarWidth: CGFloat = 14
    static let bubbleHeaderGap: CGFloat = 5
    static let bubbleHeaderFontSize: CGFloat = 11.2
    static let bubbleDetailFontSize: CGFloat = 11.8
    static let menuVisualSize = CGSize(width: 22, height: 22)
    static let menuHitSize = CGSize(width: 36, height: 36)
    static let resizeVisualSize = CGSize(width: 16, height: 16)
    static let resizeHitSize = CGSize(width: 38, height: 38)
    static let pointerNearMargin: CGFloat = 12
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
        content: OverlayBubbleContent = .idle
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
        return CGRect(
            x: bubbleRect.maxX - 34,
            y: bubbleRect.minY,
            width: 34,
            height: min(headerHitHeight, bubbleRect.height)
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
        content.sessions.map { session in
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
        clickMenuEnabled: Bool
    ) -> CGRect {
        var rects = [
            rect(center: petScreenCenter, size: petVisibleSize(scale: scale)),
            rect(center: petScreenCenter, size: petDragSize(scale: scale)),
            rect(center: resizeScreenCenter(petScreenCenter: petScreenCenter, scale: scale), size: resizeHitSize)
        ]

        if clickMenuEnabled {
            rects.append(rect(center: menuScreenCenter(petScreenCenter: petScreenCenter, scale: scale), size: menuHitSize))
        }

        let union = rects.dropFirst().reduce(rects[0]) { partial, rect in
            partial.union(rect)
        }
        return union.insetBy(dx: -pointerNearMargin, dy: -pointerNearMargin)
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
        content: OverlayBubbleContent = .idle,
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
        bubbleContent: OverlayBubbleContent = .idle
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
        bubbleContent: OverlayBubbleContent = .idle
    ) -> [CGRect] {
        let displayPetCenter = petCenter
        let menuCenter = menuCenter(petCenter: displayPetCenter, scale: scale)
        var rects: [CGRect] = [
            rect(center: displayPetCenter, size: petDragSize(scale: scale))
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
        bubbleContent: OverlayBubbleContent = .idle
    ) -> Bool {
        interactiveRects(
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
        .contains { $0.contains(point) }
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
        )
    }

    private static func measuredSessionRowHeight(
        width: CGFloat,
        session: OverlaySessionContent
    ) -> CGFloat {
        let textWidth = max(
            76,
            width - bubbleLeadingPadding - bubbleTrailingPadding
                - bubbleSessionHorizontalPadding * 2
        )
        let titleHeight = lineHeight(
            for: .systemFont(ofSize: bubbleSessionTitleFontSize, weight: .semibold)
        )
        let detailFont = NSFont.systemFont(ofSize: bubbleDetailFontSize, weight: .medium)
        let detailLineHeight = lineHeight(for: detailFont)
        let detailHeight = measuredTextHeight(
            session.messageText,
            font: detailFont,
            width: textWidth,
            lineHeight: detailLineHeight,
            maximumLines: bubbleDetailLineLimit
        )
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
}

struct OverlaySessionContent: Equatable, Identifiable {
    var id: String
    var source: AgentSource?
    var sessionID: String?
    var eventType: AgentEventKind?
    var sessionTitle: String
    var messageText: String
    var statusText: String
    var actionLabel: String
    var navigation: AgentSessionNavigation

    var canOpen: Bool { !navigation.explicitlyClosed }

    static let idle = OverlaySessionContent(
        id: "idle",
        source: nil,
        sessionID: nil,
        eventType: nil,
        sessionTitle: "Agent Pet Companion",
        messageText: APCLocalization.text(.overlayIdleDetail),
        statusText: "",
        actionLabel: APCLocalization.text(.overlayActionOpen),
        navigation: AgentSessionNavigation()
    )

    init(
        id: String,
        source: AgentSource?,
        sessionID: String?,
        eventType: AgentEventKind?,
        sessionTitle: String,
        messageText: String,
        statusText: String,
        actionLabel: String,
        navigation: AgentSessionNavigation = AgentSessionNavigation()
    ) {
        self.id = id
        self.source = source
        self.sessionID = sessionID
        self.eventType = eventType
        self.sessionTitle = sessionTitle
        self.messageText = messageText
        self.statusText = statusText
        self.actionLabel = actionLabel
        self.navigation = navigation
    }

    init(state: ActiveAgentState) {
        let event = state.event
        id = event.id
        source = event.source
        sessionID = state.sessionID ?? event.sessionID
        eventType = event.eventType
        sessionTitle = Self.sessionTitle(for: state)
        statusText = Self.statusText(for: event.eventType)
        actionLabel = Self.actionLabel(for: event.eventType)
        navigation = event.sessionNavigation
        messageText = Self.displayMessage(for: state)
    }

    init(event: AgentEvent) {
        id = event.id
        source = event.source
        sessionID = event.sessionID
        eventType = event.eventType
        sessionTitle = Self.compactTitle(event.payloadJSON?.projectLabel)
            ?? "\(event.source.shortTitle) 会话"
        statusText = Self.statusText(for: event.eventType)
        actionLabel = Self.actionLabel(for: event.eventType)
        navigation = event.sessionNavigation
        messageText = event.payloadJSON?.messageRole == "assistant"
            ? event.messageContent ?? Self.fallbackDetail(for: event.eventType)
            : Self.fallbackDetail(for: event.eventType)
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
        if state.latestUserMessage?.payloadJSON?.messageRole == "user",
           let title = compactTitle(state.latestUserMessage?.messageContent)
        {
            return title
        }
        if state.event.payloadJSON?.messageRole == "user",
           let title = compactTitle(state.event.messageContent)
        {
            return title
        }
        return compactTitle(state.event.payloadJSON?.projectLabel)
            ?? "\(state.source.shortTitle) 会话"
    }

    private static func assistantMessage(for state: ActiveAgentState) -> String? {
        if state.sessionMessage?.role == "assistant",
           let message = compactMessage(state.sessionMessage?.content)
        {
            return message
        }
        if state.latestMessage?.payloadJSON?.messageRole == "assistant",
           let message = compactMessage(state.latestMessage?.messageContent)
        {
            return message
        }
        if state.event.payloadJSON?.messageRole == "assistant" {
            return compactMessage(state.event.messageContent)
        }
        return nil
    }

    private static func displayMessage(for state: ActiveAgentState) -> String {
        switch state.event.eventType {
        case .waiting, .failed:
            return fallbackDetail(for: state.event.eventType)
        case .start, .tool:
            return activityMessage(for: state)
                ?? assistantMessage(for: state)
                ?? fallbackDetail(for: state.event.eventType)
        case .review, .done:
            return assistantMessage(for: state)
                ?? fallbackDetail(for: state.event.eventType)
        }
    }

    private static func activityMessage(for state: ActiveAgentState) -> String? {
        if let content = compactMessage(state.sessionActivity?.content) {
            return content
        }
        guard let kind = state.sessionActivity?.kind else { return nil }
        let key: APCLocalizationKey = switch kind {
        case "thinking": .overlayActivityThinking
        case "plan": .overlayActivityPlan
        case "command": .overlayActivityCommand
        case "file": .overlayActivityFile
        case "file_change": .overlayActivityFileChange
        case "tool": .overlayActivityTool
        case "subagent": .overlayActivitySubagent
        case "search": .overlayActivitySearch
        case "network": .overlayActivityNetwork
        case "image": .overlayActivityImage
        case "compaction": .overlayActivityCompaction
        default: .overlayDetailRunning
        }
        return APCLocalization.text(key)
    }

    private static func compactTitle(_ value: String?) -> String? {
        guard let value = compactMessage(value) else { return nil }
        let firstLine = value.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? value
        return firstLine.count > 80 ? "\(firstLine.prefix(79))…" : firstLine
    }

    private static func compactMessage(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func statusText(for eventType: AgentEventKind) -> String {
        switch eventType {
        case .start: APCLocalization.text(.overlayStatusRunning)
        case .tool: APCLocalization.text(.overlayStatusTool)
        case .waiting: APCLocalization.text(.overlayStatusNeedsInput)
        case .review, .done: APCLocalization.text(.overlayStatusReady)
        case .failed: APCLocalization.text(.overlayStatusBlocked)
        }
    }

    private static func fallbackDetail(for eventType: AgentEventKind) -> String {
        switch eventType {
        case .start, .tool: APCLocalization.text(.overlayDetailRunning)
        case .waiting: APCLocalization.text(.overlayDetailNeedsInput)
        case .review, .done: APCLocalization.text(.overlayDetailReady)
        case .failed: APCLocalization.text(.overlayDetailBlocked)
        }
    }

    private static func actionLabel(for eventType: AgentEventKind) -> String {
        APCLocalization.text(.overlayActionOpen)
    }
}

struct OverlayBubbleContent: Equatable, Identifiable {
    var id: String
    var source: AgentSource?
    var agentName: String
    var sessions: [OverlaySessionContent]

    var eventIDs: [String] { sessions.map(\.id) }

    static let idle = OverlayBubbleContent(
        id: "idle",
        source: nil,
        agentName: "Agent",
        sessions: [.idle]
    )

    init(
        id: String,
        source: AgentSource?,
        agentName: String,
        sessions: [OverlaySessionContent]
    ) {
        self.id = id
        self.source = source
        self.agentName = agentName
        self.sessions = sessions
    }

    init(source: AgentSource, states: [ActiveAgentState]) {
        id = "agent-\(source.rawValue)"
        self.source = source
        agentName = source.title
        sessions = states.map(OverlaySessionContent.init(state:))
    }

    init(state: ActiveAgentState) {
        self.init(source: state.source, states: [state])
    }

    init(event: AgentEvent?) {
        guard let event else {
            self = .idle
            return
        }
        id = "agent-\(event.source.rawValue)"
        source = event.source
        agentName = event.source.title
        sessions = [OverlaySessionContent(event: event)]
    }
}
