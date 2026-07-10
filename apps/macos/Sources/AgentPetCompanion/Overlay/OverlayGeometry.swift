import AppKit
import AgentPetCompanionCore
import CoreGraphics

struct OverlayDisplayGeometry: Equatable, Sendable {
    var frame: CGRect
    var visibleFrame: CGRect
    var backingScaleFactor: CGFloat
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
    static let bubbleWidth: CGFloat = 300
    static let bubbleMinimumHeight: CGFloat = 44
    static let bubbleMaximumHeight: CGFloat = 66
    static let bubbleGap: CGFloat = 6
    static let bubbleMinimumWidth: CGFloat = 108
    static let bubbleStackSpacing: CGFloat = 6
    static let bubbleCornerRadius: CGFloat = 15
    static let bubbleLeadingPadding: CGFloat = 12
    static let bubbleTrailingPadding: CGFloat = 50
    static let bubbleVerticalPadding: CGFloat = 12
    static let bubbleHeaderAvatarWidth: CGFloat = 14
    static let bubbleHeaderGap: CGFloat = 5
    static let bubbleHeaderFontSize: CGFloat = 11.2
    static let bubbleDetailFontSize: CGFloat = 11.8
    static let menuVisualSize = CGSize(width: 24, height: 24)
    static let menuHitSize = CGSize(width: 36, height: 36)
    static let resizeVisualSize = CGSize(width: 18, height: 18)
    static let resizeHitSize = CGSize(width: 38, height: 38)
    static let pointerNearMargin: CGFloat = 3
    private static let petStageBaseSize = CGSize(width: 250, height: 330)
    private static let petShadowRadius: CGFloat = 14
    private static let petShadowYOffset: CGFloat = 8
    private static let panelContentPadding: CGFloat = 3

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
        let width = min(maximumWidth, max(minimumWidth, measuredBubbleWidth(maximumWidth: maximumWidth, content: content)))
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
        includeResize: Bool = true
    ) -> CGPoint {
        guard !visibleFrame.isEmpty else { return proposedCenter }

        let relativeBounds = petInteractiveScreenBounds(
            scale: scale,
            petScreenCenter: .zero,
            clickMenuEnabled: clickMenuEnabled,
            includeResize: includeResize
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
        screenFrame: CGRect
    ) -> CGPoint {
        let petSize = petVisibleSize(scale: scale)
        let petLeft = petScreenCenter.x - petSize.width / 2
        let petRight = petScreenCenter.x + petSize.width / 2
        let petTop = petScreenCenter.y + petSize.height / 2
        let petBottom = petScreenCenter.y - petSize.height / 2

        let alignLeft = screenFrame.isEmpty ? false : petScreenCenter.x < screenFrame.midX
        let aboveCenter = petTop + bubbleGap + bubbleSize.height / 2
        let belowCenter = petBottom - bubbleGap - bubbleSize.height / 2
        let hasSpaceAbove = screenFrame.isEmpty || aboveCenter <= screenFrame.maxY - 8
        let hasSpaceBelow = screenFrame.isEmpty || belowCenter >= screenFrame.minY + 8
        let placeBelow: Bool
        if !hasSpaceAbove, hasSpaceBelow {
            placeBelow = true
        } else if !hasSpaceBelow, hasSpaceAbove {
            placeBelow = false
        } else {
            placeBelow = screenFrame.isEmpty ? false : petScreenCenter.y > screenFrame.midY
        }

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

    static func resizeCenter(petCenter: CGPoint, scale: CGFloat) -> CGPoint {
        let petSize = petVisibleSize(scale: scale)
        return CGPoint(
            x: petCenter.x + petSize.width / 2 + 8,
            y: petCenter.y + petSize.height / 2 + 8
        )
    }

    static func resizeScreenCenter(petScreenCenter: CGPoint, scale: CGFloat) -> CGPoint {
        let petSize = petVisibleSize(scale: scale)
        return CGPoint(
            x: petScreenCenter.x + petSize.width / 2 + 8,
            y: petScreenCenter.y - petSize.height / 2 - 8
        )
    }

    static func menuCenter(petCenter: CGPoint, scale: CGFloat) -> CGPoint {
        let petSize = petVisibleSize(scale: scale)
        return CGPoint(
            x: petCenter.x + petSize.width / 2 + 14,
            y: petCenter.y - petSize.height / 2 + 10
        )
    }

    static func menuScreenCenter(petScreenCenter: CGPoint, scale: CGFloat) -> CGPoint {
        let petSize = petVisibleSize(scale: scale)
        return CGPoint(
            x: petScreenCenter.x + petSize.width / 2 + 14,
            y: petScreenCenter.y + petSize.height / 2 - 10
        )
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
        content: OverlayBubbleContent = .idle
    ) -> CGRect {
        bubblePanelScreenFrame(
            scale: scale,
            petScreenCenter: petScreenCenter,
            visibleFrame: visibleFrame,
            contents: [content]
        )
    }

    static func bubblePanelScreenFrame(
        scale: CGFloat,
        petScreenCenter: CGPoint,
        visibleFrame: CGRect,
        contents: [OverlayBubbleContent]
    ) -> CGRect {
        let bubbleSize = resolvedBubbleStackSize(in: visibleFrame.size, contents: contents)
        guard bubbleSize.width > 0, bubbleSize.height > 0 else { return .zero }
        return rect(
            center: bubbleScreenCenter(
                bubbleSize: bubbleSize,
                scale: scale,
                petScreenCenter: petScreenCenter,
                screenFrame: visibleFrame
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

    private static func measuredBubbleWidth(maximumWidth: CGFloat, content: OverlayBubbleContent) -> CGFloat {
        let textWidthLimit = max(72, maximumWidth - bubbleLeadingPadding - bubbleTrailingPadding)
        let headerFont = NSFont.systemFont(ofSize: bubbleHeaderFontSize, weight: .semibold)
        let detailFont = NSFont.systemFont(ofSize: bubbleDetailFontSize, weight: .semibold)
        let headerWidth = bubbleHeaderAvatarWidth + bubbleHeaderGap
            + measuredSingleLineWidth(content.agentName, font: headerFont)
        let detailWidth = naturalDetailWidth(
            content.messageText,
            font: detailFont,
            maximumWidth: textWidthLimit,
            minimumReadableWidth: 76
        )
        return ceil(bubbleLeadingPadding + bubbleTrailingPadding + max(headerWidth, detailWidth))
    }

    private static func measuredBubbleHeight(width: CGFloat, content: OverlayBubbleContent) -> CGFloat {
        let spacing: CGFloat = 2
        let textWidth = max(76, width - bubbleLeadingPadding - bubbleTrailingPadding)
        let headerHeight = lineHeight(for: .systemFont(ofSize: bubbleHeaderFontSize, weight: .semibold))
        let detailFont = NSFont.systemFont(ofSize: bubbleDetailFontSize, weight: .semibold)
        let detailLineHeight = lineHeight(for: detailFont)
        let detailHeight = measuredTextHeight(
            content.messageText,
            font: detailFont,
            width: textWidth,
            lineHeight: detailLineHeight,
            maximumLines: 2
        )
        return ceil(bubbleVerticalPadding + headerHeight + spacing + detailHeight)
    }

    private static func naturalDetailWidth(
        _ text: String,
        font: NSFont,
        maximumWidth: CGFloat,
        minimumReadableWidth: CGFloat
    ) -> CGFloat {
        let singleLineWidth = measuredSingleLineWidth(text, font: font)
        guard singleLineWidth > maximumWidth else {
            return singleLineWidth
        }

        // A two-line bubble should not jump straight to the maximum width if the
        // message can wrap cleanly at a narrower, readable width.
        let twoLineTarget = ceil(singleLineWidth / 2) + 12
        return min(maximumWidth, max(minimumReadableWidth, twoLineTarget))
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

struct OverlayBubbleContent: Equatable, Identifiable {
    var id: String
    var source: AgentSource?
    var eventType: AgentEventKind?
    var agentName: String
    var title: String
    var detail: String

    var messageText: String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? title : trimmed
    }

    static let idle = OverlayBubbleContent(
        id: "idle",
        source: nil,
        eventType: nil,
        agentName: "Agent",
        title: "Agent Pet Companion",
        detail: "宠物正在等待 Agent 事件。"
    )

    init(
        id: String,
        source: AgentSource?,
        eventType: AgentEventKind?,
        agentName: String,
        title: String,
        detail: String
    ) {
        self.id = id
        self.source = source
        self.eventType = eventType
        self.agentName = agentName
        self.title = title
        self.detail = detail
    }

    init(event: AgentEvent?) {
        guard let event else {
            self = .idle
            return
        }
        id = event.id
        source = event.source
        eventType = event.eventType
        agentName = event.source.shortTitle
        title = event.title
        if
            let detail = event.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
            !detail.isEmpty,
            detail != event.source.title
        {
            self.detail = detail
            return
        }
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            detail = title
            return
        }
        switch event.eventType {
        case .start:
            detail = "开始处理任务"
        case .tool:
            detail = "正在执行工具"
        case .waiting:
            detail = "正在等待确认"
        case .review:
            detail = "有内容待查看"
        case .done:
            detail = "已完成任务"
        case .failed:
            detail = "处理失败"
        }
    }
}
