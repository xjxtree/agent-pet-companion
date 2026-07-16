import AppKit
import SwiftUI
import Testing
@testable import AgentPetCompanion

@Suite
struct BubbleGlassRegressionTests {
    @Test
    func maximumClearSurfaceAddsNoSolidBackdrop() {
        #expect(APCBubbleGlassStyle.backdropOpacity == 0)
        #expect(APCBubbleGlassStyle.borderOpacity == 0)
        #expect(APCBubbleGlassStyle.legacyBackdropOpacity > 0)
    }

    @Test
    func clearSurfaceNeverAttenuatesItsForeground() {
        #expect(APCBubbleForegroundStyle.contentOpacity == 1)
        #expect(APCBubbleForegroundStyle.secondaryContentOpacity == 1)
        #expect(APCBubbleForegroundStyle.lightHaloOpacity > 0)
        #expect(APCBubbleForegroundStyle.darkHaloOpacity > 0)
        #expect(APCBubbleForegroundStyle.darkHaloOpacity > APCBubbleForegroundStyle.lightHaloOpacity)
    }

#if compiler(>=6.2)
    @Test @MainActor
    @available(macOS 26.0, *)
    func nativeMaximumClearGlassOwnsItsForegroundContentView() {
        let contentView = APCNativeBubbleGlassConfiguration.makeHostingView(
            rootView: ZStack {
                Color.clear
                Text("Codex")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {}
        )
        #expect(contentView.sizingOptions == [.intrinsicContentSize])
        #expect(contentView.fittingSize.width > 0)
        #expect(contentView.fittingSize.height > 0)

        let glassView = APCNativeBubbleGlassConfiguration.makeView(
            contentView: contentView,
            cornerRadius: 21
        )

        #expect(glassView.style == .clear)
        #expect(glassView.tintColor == nil)
        #expect(glassView.cornerRadius == 21)
        #expect(glassView.alphaValue == 1)
        #expect(glassView.contentView === contentView)

        glassView.frame = NSRect(x: 0, y: 0, width: 360, height: 190)
        glassView.layoutSubtreeIfNeeded()
        #expect(contentView.frame == glassView.bounds)
        let farEdgeHit = glassView.hitTest(NSPoint(x: 350, y: 180))
        #expect(
            farEdgeHit === contentView
                || farEdgeHit?.isDescendant(of: contentView) == true
        )

        let proposedSize = APCNativeBubbleGlassConfiguration.resolvedSize(
            proposal: ProposedViewSize(width: nil, height: 210),
            fittingSize: contentView.fittingSize
        )
        #expect(proposedSize.width == contentView.fittingSize.width)
        #expect(proposedSize.height == 210)
    }
#endif

    @Test
    func accessibilityFallbacksRemainDarkerThanLegacyMaterial() {
        #expect(
            APCBubbleGlassStyle.increasedContrastBackdropOpacity
                > APCBubbleGlassStyle.legacyBackdropOpacity
        )
        #expect(
            APCBubbleGlassStyle.reducedTransparencyBackdropOpacity
                > APCBubbleGlassStyle.increasedContrastBackdropOpacity
        )
        #expect(
            APCBubbleGlassStyle.reducedTransparencyBorderOpacity
                > APCBubbleGlassStyle.legacyBorderOpacity
        )
    }
}
