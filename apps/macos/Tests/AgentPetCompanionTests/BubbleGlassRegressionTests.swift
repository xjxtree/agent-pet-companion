import AppKit
import AgentPetCompanionCore
import SwiftUI
import Testing
@testable import AgentPetCompanion

@Suite
struct BubbleGlassRegressionTests {
    @Test
    func adjustableClearSurfaceKeepsAVisibleNativeLensWithoutSolidBackdrop() {
        #expect(APCBubbleGlassStyle.backdropOpacity == 0)
        #expect(APCBubbleGlassStyle.borderOpacity == 0)
        #expect(APCBubbleGlassStyle.minimumOpticalOpacity >= 0.30)
        #expect(APCBubbleGlassStyle.maximumOpticalOpacity <= 1)
        #expect(
            APCBubbleGlassStyle.opticalOpacity(for: 0)
                > APCBubbleGlassStyle.opticalOpacity(for: 1)
        )
        #expect(
            APCBubbleGlassStyle.resolvedBackdropOpacity(
                reduceTransparency: false,
                increasedContrast: false
            ) == 0
        )
        #expect(
            APCBubbleGlassStyle.resolvedBorderOpacity(
                reduceTransparency: false,
                increasedContrast: false,
                supportsLiquidGlass: true
            ) == 0
        )
        #expect(APCBubbleGlassStyle.legacyBackdropOpacity > 0)
        #expect(
            APCBubbleGlassStyle.resolvedLegacyBackdropOpacity(for: 0)
                > APCBubbleGlassStyle.resolvedLegacyBackdropOpacity(for: 1)
        )
    }

    @Test
    func clearSurfaceNeverAttenuatesItsForeground() {
        #expect(APCBubbleForegroundStyle.contentOpacity == 1)
        #expect(APCBubbleForegroundStyle.secondaryContentOpacity == 1)
        #expect(!APCBubbleForegroundStyle.usesBlur)
        #expect(!APCBubbleForegroundStyle.usesHalo)
    }

#if compiler(>=6.2)
    @Test @MainActor
    @available(macOS 26.0, *)
    func nativeAdjustableClearGlassKeepsForegroundAboveOpticalSibling() {
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

        let surfaceView = APCNativeBubbleGlassConfiguration.makeView(
            contentView: contentView,
            cornerRadius: 21
        )

        #expect(surfaceView.glassView.style == .clear)
        #expect(surfaceView.glassView.tintColor == nil)
        #expect(surfaceView.glassView.cornerRadius == 21)
        #expect(
            abs(
                Double(surfaceView.glassView.alphaValue)
                    - APCBubbleGlassStyle.opticalOpacity(
                        for: BehaviorSettings.defaultBubbleTransparency
                    )
            ) < 0.000_1
        )
        APCNativeBubbleGlassConfiguration.configureAppearance(
            surfaceView.glassView,
            cornerRadius: 21,
            transparency: 1
        )
        #expect(
            abs(
                Double(surfaceView.glassView.alphaValue)
                    - APCBubbleGlassStyle.minimumOpticalOpacity
            ) < 0.000_1
        )
        APCNativeBubbleGlassConfiguration.configureAppearance(
            surfaceView.glassView,
            cornerRadius: 21,
            transparency: 0
        )
        #expect(
            abs(
                Double(surfaceView.glassView.alphaValue)
                    - APCBubbleGlassStyle.maximumOpticalOpacity
            ) < 0.000_1
        )
        #expect(surfaceView.foregroundView === contentView)
        #expect(surfaceView.glassView.contentView == nil)
        #expect(surfaceView.subviews.first === surfaceView.glassView)
        #expect(surfaceView.subviews.last === contentView)

        surfaceView.frame = NSRect(x: 0, y: 0, width: 360, height: 190)
        surfaceView.layoutSubtreeIfNeeded()
        #expect(surfaceView.glassView.frame == surfaceView.bounds)
        #expect(contentView.frame == surfaceView.bounds)
        #expect(surfaceView.glassView.hitTest(NSPoint(x: 350, y: 180)) == nil)
        let farEdgeHit = surfaceView.hitTest(NSPoint(x: 350, y: 180))
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
