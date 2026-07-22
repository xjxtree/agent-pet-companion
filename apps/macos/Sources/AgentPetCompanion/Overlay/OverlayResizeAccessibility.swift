import AppKit

@MainActor
final class OverlayResizeAccessibilityView: NSView {
    var scale: CGFloat = OverlayGeometry.defaultScale {
        didSet {
            setAccessibilityValue(Double(scale))
            setAccessibilityValueDescription(Self.valueDescription(for: scale))
        }
    }
    var onHoverChanged: (Bool) -> Void = { _ in }
    var onFocusChanged: (Bool) -> Void = { _ in }
    var onResizeActiveChanged: (Bool) -> Void = { _ in }
    var onResizeChanged: (CGFloat, CGSize) -> Void = { _, _ in }
    var onResizeEnded: (CGFloat, CGSize) -> Void = { _, _ in }
    var onScaleStep: (CGFloat) -> Void = { _ in }

    private var resizeStartScale: CGFloat?
    private var resizeStartMouseLocation: NSPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var acceptsFirstResponder: Bool { true }

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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged(true)
    }

    override func mouseExited(with event: NSEvent) {
        if resizeStartScale == nil {
            onHoverChanged(false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        resizeStartScale = scale
        resizeStartMouseLocation = NSEvent.mouseLocation
        window?.ignoresMouseEvents = false
        onResizeActiveChanged(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let resizeStartScale, let resizeStartMouseLocation else { return }
        onResizeChanged(resizeStartScale, screenTranslation(from: resizeStartMouseLocation))
    }

    override func mouseUp(with event: NSEvent) {
        guard let resizeStartScale, let resizeStartMouseLocation else {
            onResizeActiveChanged(false)
            return
        }
        onResizeEnded(resizeStartScale, screenTranslation(from: resizeStartMouseLocation))
        self.resizeStartScale = nil
        self.resizeStartMouseLocation = nil
        onResizeActiveChanged(false)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125:
            performScaleStep(-OverlayGeometry.resizeStep)
        case 124, 126:
            performScaleStep(OverlayGeometry.resizeStep)
        default:
            switch event.charactersIgnoringModifiers {
            case "+", "=":
                performScaleStep(OverlayGeometry.resizeStep)
            case "-", "_":
                performScaleStep(-OverlayGeometry.resizeStep)
            default:
                super.keyDown(with: event)
            }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            needsDisplay = true
            onFocusChanged(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            needsDisplay = true
            onFocusChanged(false)
        }
        return resigned
    }

    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 3, dy: 3) }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 7, yRadius: 7).fill()
    }

    override func accessibilityPerformIncrement() -> Bool {
        performScaleStep(OverlayGeometry.resizeStep)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        performScaleStep(-OverlayGeometry.resizeStep)
        return true
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(Self.accessibilityLabel(
            localeIdentifier: APCLocalization.interfaceLocaleIdentifier
        ))
        setAccessibilityHelp(Self.accessibilityHelp(
            localeIdentifier: APCLocalization.interfaceLocaleIdentifier
        ))
        setAccessibilityMinValue(Double(OverlayGeometry.minimumScale))
        setAccessibilityMaxValue(Double(OverlayGeometry.maximumScale))
        setAccessibilityValue(Double(scale))
        setAccessibilityValueDescription(Self.valueDescription(for: scale))
    }

    private func performScaleStep(_ step: CGFloat) {
        onScaleStep(step)
        NSAccessibility.post(
            element: self,
            notification: .valueChanged,
            userInfo: [.announcement: Self.valueDescription(for: OverlayGeometry.clampedScale(scale + step))]
        )
    }

    private func screenTranslation(from start: NSPoint) -> CGSize {
        let current = NSEvent.mouseLocation
        return CGSize(width: current.x - start.x, height: start.y - current.y)
    }

    private static func valueDescription(for scale: CGFloat) -> String {
        "\(Int((scale * 100).rounded()))%"
    }

    static func accessibilityLabel(localeIdentifier: String) -> String {
        APCLocalization.text(.configDisplaySize, locale: localeIdentifier)
    }

    static func accessibilityHelp(localeIdentifier: String) -> String {
        APCLocalization.text(.overlayResizeHelp, locale: localeIdentifier)
    }
}
