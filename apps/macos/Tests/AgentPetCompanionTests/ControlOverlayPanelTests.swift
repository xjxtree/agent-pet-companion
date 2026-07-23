import AppKit
import Testing
@testable import AgentPetCompanion

@MainActor
@Suite("Control overlay panel")
struct ControlOverlayPanelTests {
    @Test
    func controlLevelStaysAboveFloatingOverlayContent() {
        #expect(ControlOverlayPanel.overlayWindowLevel.rawValue > NSWindow.Level.floating.rawValue)
    }

    @Test
    func primaryClickDispatchesOnceOnMouseUp() throws {
        let panel = makePanel()
        let center = NSPoint(x: panel.frame.width / 2, y: panel.frame.height / 2)
        var actionCount = 0
        panel.onPrimaryAction = { actionCount += 1 }

        panel.sendEvent(try mouseEvent(.leftMouseDown, at: center))
        #expect(actionCount == 0)

        panel.sendEvent(try mouseEvent(.leftMouseUp, at: center))
        #expect(actionCount == 1)
    }

    @Test
    func primaryClickCancelsWhenReleasedOutside() throws {
        let panel = makePanel()
        let center = NSPoint(x: panel.frame.width / 2, y: panel.frame.height / 2)
        let outside = NSPoint(x: panel.frame.width + 8, y: center.y)
        var actionCount = 0
        panel.onPrimaryAction = { actionCount += 1 }

        panel.sendEvent(try mouseEvent(.leftMouseDown, at: center))
        panel.sendEvent(try mouseEvent(.leftMouseDragged, at: outside))
        panel.sendEvent(try mouseEvent(.leftMouseUp, at: outside))

        #expect(actionCount == 0)
    }

    @Test
    func bubblePanelSupportsExplicitFullKeyboardNavigation() {
        let panel = BubbleOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
    }

    @Test
    func bubblePanelRestoresPassiveFocusStateWhenKeyboardNavigationEnds() {
        let panel = BubbleOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        var focusTransitions: [Bool] = []
        panel.onKeyboardNavigationChanged = {
            focusTransitions.append($0)
        }

        panel.becomeKey()
        panel.resignKey()

        #expect(focusTransitions == [true, false])
    }

    @Test
    func overlayGroupsAndSessionsExposeStableAXIdentifiersAndActions() throws {
        let overlaySource = try String(
            contentsOf: sourceDirectory.appendingPathComponent(
                "Overlay/OverlayRootView.swift"
            ),
            encoding: .utf8
        )
        let sharedSource = try String(
            contentsOf: sourceDirectory.appendingPathComponent(
                "Views/SharedProductComponents.swift"
            ),
            encoding: .utf8
        )

        #expect(overlaySource.contains(
            #".accessibilityIdentifier("overlay.group.\(content.id)")"#
        ))
        #expect(sharedSource.contains(
            #".accessibilityIdentifier("overlay.session.\(session.id)")"#
        ))
        #expect(sharedSource.contains("SessionBubbleAccessibilityActions("))
        #expect(overlaySource.contains("ConversationBubbleAccessibilityActions("))
    }

    private func makePanel() -> ControlOverlayPanel {
        let frame = NSRect(origin: .zero, size: OverlayGeometry.menuHitSize)
        let panel = ControlOverlayPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSView(frame: frame)
        return panel
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
    }

    private var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentPetCompanion", isDirectory: true)
    }
}
