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
    func nativeLiquidGlassOwnsItsForegroundWithoutASiblingBackingPlate() {
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

        #expect(surface.contentView === foreground)
        #expect(surface.foregroundView === foreground)
        #expect(surface.foregroundView.frame == surface.bounds)
        #expect(surface.style == .regular)
        #expect(surface.alphaValue == 1)
        #expect(surface.tintColor == nil)
        #expect(!surface.isOpaque)
        #expect(surface.layer?.isOpaque == false)
    }
}
#endif
