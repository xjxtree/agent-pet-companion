import AppKit
import AgentPetCompanionCore
import SwiftUI
import Testing
@testable import AgentPetCompanion

@Suite
struct BubbleGlassRegressionTests {
    @Test
    func bubbleUsesOneOuterGlassWithoutNestedSessionControlGlass() throws {
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

        #expect(bubbleSource.components(separatedBy: ".apcNativeBubbleGlass").count - 1 == 1)
        #expect(!bubbleSource.contains("glassTransparency"))
        #expect(!bubbleSource.contains("bubbleTransparency"))
        #expect(!bubbleSource.contains(".apcClearGlass"))
        #expect(countButtonSource.contains("Capsule()"))
        #expect(bubbleSource.contains(
            ".fill((content.statusTone.color ?? .clear).opacity(0.12))"
        ))
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

        // Glass and foreground stay ordered siblings. Installing the hosting
        // view as NSGlassEffectView.contentView can leave only the optical
        // layer visible inside a transparent NSPanel.
        #expect(source.contains("addSubview(glassView)"))
        #expect(source.contains("addSubview(foregroundView)"))
        #expect(!source.contains("glassView.contentView"))

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
    func opticalRimIsAThinReflectionCueRatherThanAnotherMaterialLayer() throws {
        #expect(APCBubbleGlassStyle.opticalRimWidth > 0)
        #expect(APCBubbleGlassStyle.opticalRimWidth < 1)
        #expect(
            APCBubbleGlassStyle.opticalRimHighlightOpacity
                > APCBubbleGlassStyle.opticalRimMidpointOpacity
        )
        #expect(
            APCBubbleGlassStyle.opticalRimHighlightOpacity
                > APCBubbleGlassStyle.opticalRimDepthOpacity
        )

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
        let settingsSource = try String(
            contentsOf: macOSRoot.appendingPathComponent(
                "Sources/AgentPetCompanion/Views/BehaviorSettingsView.swift"
            ),
            encoding: .utf8
        )

        #expect(designSource.contains(".strokeBorder("))
        #expect(designSource.contains("LinearGradient("))
        #expect(designSource.contains("private var bubbleOpticalRim"))
        #expect(geometrySource.contains("static let bubbleCornerRadius: CGFloat = 20"))
        #expect(settingsSource.contains(
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
