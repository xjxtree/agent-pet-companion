import AppKit
import SwiftUI
import Testing
@testable import AgentPetCompanion

#if compiler(>=6.2)
@Suite
@MainActor
struct BubbleGlassRenderingTests {
    @Test @MainActor
    @available(macOS 26.0, *)
    func nativeLiquidGlassKeepsForegroundAsTheTopSibling() {
        let size = CGSize(width: 320, height: 112)
        let foreground = APCNativeBubbleGlassConfiguration.makeHostingView(
            rootView: Text("Codex session is running")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color.primary)
        )
        let surface = APCNativeBubbleGlassConfiguration.makeView(
            contentView: foreground,
            cornerRadius: 18
        )
        surface.frame = NSRect(origin: .zero, size: size)
        surface.layoutSubtreeIfNeeded()

        #expect(surface.subviews.count == 2)
        #expect(surface.subviews.first === surface.glassView)
        #expect(surface.subviews.last === surface.foregroundView)
        #expect(surface.foregroundView.frame == surface.bounds)
        #expect(surface.glassView.frame == surface.bounds)
        #expect(surface.glassView.style == .regular)
        #expect(surface.glassView.alphaValue == 1)
        #expect(surface.glassView.tintColor == nil)
    }
}
#endif
