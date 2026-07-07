import AppKit
import SwiftUI

@MainActor
final class PetOverlayController {
    private var panel: NSPanel?

    func show(store: AppStore) {
        if panel != nil {
            setVisible(store.behavior.enabled)
            return
        }

        let root = OverlayRootView()
            .environmentObject(store)
        let hostingView = NSHostingView(rootView: root)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = NSPanel(
            contentRect: NSRect(x: 860, y: 180, width: 520, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.orderFrontRegardless()
        self.panel = panel
        setVisible(store.behavior.enabled)
    }

    func setVisible(_ visible: Bool) {
        if visible {
            panel?.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    func updateScale(_ scale: CGFloat) {
        guard let panel else { return }
        let width = 420 * scale
        let height = 340 * scale
        var frame = panel.frame
        frame.size = NSSize(width: width, height: height)
        panel.setFrame(frame, display: true, animate: false)
    }
}
