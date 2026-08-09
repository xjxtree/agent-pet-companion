import AppKit
import AgentPetCompanionCore
import SwiftUI
import Testing
@testable import AgentPetCompanion

@Suite
struct BubbleGlassRegressionTests {
    @Test
    func foregroundAndFoldedCardsShareNativeGlassWithoutNestedControlGlass() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let macOSRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = macOSRoot.appendingPathComponent(
            "Sources/AgentPetCompanion/Overlay/OverlayRootView.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let conversationStart = try #require(source.range(of: "private struct ConversationBubble"))
        let petStart = try #require(source.range(of: "private struct PetInteractionLayer"))
        let bubbleSource = String(source[conversationStart.lowerBound..<petStart.lowerBound])
        let countStart = try #require(bubbleSource.range(of: "private struct SessionCountButton"))
        let toneStart = try #require(bubbleSource.range(of: "private extension OverlaySessionGroupTone"))
        let countButtonSource = String(
            bubbleSource[countStart.lowerBound..<toneStart.lowerBound]
        )
        let surfaceStyleStart = try #require(
            bubbleSource.range(of: "struct ConversationBubbleSurfaceStyle")
        )
        let surfaceStyleSource = String(
            bubbleSource[surfaceStyleStart.lowerBound..<countStart.lowerBound]
        )
        let stackStart = try #require(
            bubbleSource.range(of: "private var stackDecorationLayer")
        )
        let surfaceStart = try #require(
            bubbleSource.range(of: "private var bubbleSurface")
        )
        let stackSource = String(
            bubbleSource[stackStart.lowerBound..<surfaceStart.lowerBound]
        )

        #expect(bubbleSource.components(separatedBy: ".apcNativeBubbleGlass").count - 1 == 1)
        #expect(
            bubbleSource.components(separatedBy: ".modifier(ConversationBubbleSurfaceStyle(")
                .count - 1 == 2
        )
        #expect(!bubbleSource.contains("glassTransparency"))
        #expect(!bubbleSource.contains("bubbleTransparency"))
        #expect(!bubbleSource.contains(".apcClearGlass"))
        #expect(countButtonSource.contains("Capsule()"))
        #expect(stackSource.contains("Color.clear"))
        #expect(stackSource.contains("semanticTintOpacity: 0.12"))
        #expect(stackSource.contains("statusTone: content.statusTone"))
        #expect(!stackSource.contains(".regularMaterial"))
        #expect(!stackSource.contains("Color.primary.opacity"))
        #expect(!stackSource.contains("shape.stroke"))
        #expect(!stackSource.contains(".opacity("))
        #expect(surfaceStyleSource.contains("shape.fill(color.opacity(semanticTintOpacity))"))
        #expect(bubbleSource.contains("statusTone: content.statusTone"))
        #expect(surfaceStyleSource.contains(".apcNativeBubbleGlass("))
        #expect(!surfaceStyleSource.contains(".regularMaterial"))
        #expect(!surfaceStyleSource.contains("Color.primary.opacity(0.045)"))
        #expect(countButtonSource.contains(".fill((tone.color ?? .clear).opacity(0.34))"))
        #expect(countButtonSource.contains(".stroke((tone.color ?? .clear).opacity(0.65)"))
        #expect(bubbleSource.contains("case .running: nil"))
        // A GlassEffectContainer manages SwiftUI glassEffect descendants, which
        // the AppKit bubble surface is not, and in a transparent
        // NSPanel it can elevate the optical layer above foreground content.
        // Match the call form so the prose explaining this stays allowed.
        #expect(!source.contains("GlassEffectContainer("))
        #expect(!source.contains("APCGlassGroup("))
    }

    @Test
    func bubbleUsesTheUntintedFullStrengthRegularLens() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let macOSRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = macOSRoot.appendingPathComponent(
            "Sources/AgentPetCompanion/Views/DesignSystem.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        // The system owns the adaptive material. Product settings neither fade
        // the optical layer nor place a custom veil over its backdrop.
        #expect(source.contains("glassView.style = .regular"))
        #expect(source.contains("glassView.alphaValue = 1"))
        #expect(source.contains("glassView.tintColor = nil"))
        #expect(!source.contains("veilColor"))
        #expect(!source.contains("veilOpacity"))
        #expect(!source.contains("bubbleTransparency"))

        // Geometry updates cannot trail an AppKit animation transaction.
        #expect(source.contains("CATransaction.setDisableActions(true)"))

        // AppKit owns both the rounded sampling mask and foreground placement.
        // A sibling glass view can expose its rectangular sampling backing at
        // the transparent panel boundary.
        #expect(source.contains("contentView = foregroundView"))
        #expect(!source.contains("addSubview(glassView)"))
        #expect(!source.contains("addSubview(foregroundView)"))
        #expect(source.contains("layer?.isOpaque = false"))

        // Floating overlay controls stay on the plain SwiftUI clear path.
        let controlFunctionStart = try #require(source.range(of: "func apcClearGlass"))
        let controlFunctionEnd = try #require(
            source.range(of: "\n    }", range: controlFunctionStart.upperBound..<source.endIndex)
        )
        #expect(String(
            source[controlFunctionStart.lowerBound..<controlFunctionEnd.upperBound]
        ).contains("variant: .clear"))
    }

    @Test
    func nativeBubbleUsesOnlyASubpointDualToneOpticalRim() throws {
        #expect(APCBubbleGlassStyle.opticalRimDarkWidth > 0)
        #expect(APCBubbleGlassStyle.opticalRimDarkWidth < 1)
        #expect(APCBubbleGlassStyle.opticalRimLightWidth > 0)
        #expect(APCBubbleGlassStyle.opticalRimLightWidth < 1)
        #expect(APCBubbleGlassStyle.opticalRimLightInset > 0)
        #expect(APCBubbleGlassStyle.opticalRimDarkOpacity > 0)
        #expect(APCBubbleGlassStyle.opticalRimLightOpacity > 0)

        let testFile = URL(fileURLWithPath: #filePath)
        let macOSRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let designSource = try String(
            contentsOf: macOSRoot.appendingPathComponent(
                "Sources/AgentPetCompanion/Views/DesignSystem.swift"
            ),
            encoding: .utf8
        )
        let geometrySource = try String(
            contentsOf: macOSRoot.appendingPathComponent(
                "Sources/AgentPetCompanion/Overlay/OverlayGeometry.swift"
            ),
            encoding: .utf8
        )
        let bubbleSource = try String(
            contentsOf: macOSRoot.appendingPathComponent(
                "Sources/AgentPetCompanion/Overlay/OverlayRootView.swift"
            ),
            encoding: .utf8
        )
        let modifierStart = try #require(
            designSource.range(of: "private struct APCBubbleGlassModifier")
        )
        let modifierEnd = try #require(
            designSource.range(
                of: "private struct APCClearGlassButtonStyleModifier",
                range: modifierStart.upperBound ..< designSource.endIndex
            )
        )
        let modifierSource = String(
            designSource[modifierStart.lowerBound ..< modifierEnd.lowerBound]
        )

        #expect(modifierSource.contains("private var bubbleOpticalRim"))
        #expect(modifierSource.contains("Color.black.opacity"))
        #expect(modifierSource.contains("Color.white.opacity"))
        #expect(modifierSource.contains(".inset(by: APCBubbleGlassStyle.opticalRimLightInset)"))
        #expect(!modifierSource.contains("LinearGradient("))
        #expect(modifierSource.contains("if increasedContrast"))
        #expect(modifierSource.contains("bubbleBorder(supportsLiquidGlass: true)"))
        #expect(geometrySource.contains("static let bubbleCornerRadius: CGFloat = 20"))
        #expect(bubbleSource.contains(
            "cornerRadius: OverlayGeometry.bubbleCornerRadius"
        ))
    }

    @Test
    func accessibilityFallbacksRemainDarkerThanLegacyMaterial() {
        // The normal legacy path relies on system material plus its light
        // structural border. Accessibility modes must add progressively more
        // opaque backing and stronger separation instead of inheriting that
        // translucent baseline.
        #expect(
            APCBubbleGlassStyle.increasedContrastBackdropOpacity
                > APCBubbleGlassStyle.backdropOpacity
        )
        #expect(
            APCBubbleGlassStyle.reducedTransparencyBackdropOpacity
                > APCBubbleGlassStyle.increasedContrastBackdropOpacity
        )
        #expect(
            APCBubbleGlassStyle.increasedContrastBorderOpacity
                > APCBubbleGlassStyle.legacyBorderOpacity
        )
        #expect(
            APCBubbleGlassStyle.reducedTransparencyBorderOpacity
                > APCBubbleGlassStyle.increasedContrastBorderOpacity
        )

        #expect(
            APCBubbleGlassStyle.resolvedBackdropOpacity(
                reduceTransparency: false,
                increasedContrast: true
            ) == APCBubbleGlassStyle.increasedContrastBackdropOpacity
        )
        #expect(
            APCBubbleGlassStyle.resolvedBackdropOpacity(
                reduceTransparency: true,
                increasedContrast: false
            ) == APCBubbleGlassStyle.reducedTransparencyBackdropOpacity
        )
        #expect(
            APCBubbleGlassStyle.resolvedBorderOpacity(
                reduceTransparency: true,
                increasedContrast: false,
                supportsLiquidGlass: true
            ) == APCBubbleGlassStyle.reducedTransparencyBorderOpacity
        )
    }

    @Test
    func appearanceThemesMapToNativeSchemes() {
        #expect(APCApplicationAppearance.appearanceName(for: .system) == nil)
        #expect(APCApplicationAppearance.appearanceName(for: .dark) == .darkAqua)
        #expect(APCApplicationAppearance.appearanceName(for: .light) == .aqua)
        #expect(APCApplicationAppearance.colorScheme(for: .system) == nil)
        #expect(APCApplicationAppearance.colorScheme(for: .dark) == .dark)
        #expect(APCApplicationAppearance.colorScheme(for: .light) == .light)
    }
}
