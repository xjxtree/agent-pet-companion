import AppKit
import Testing
@testable import AgentPetCompanion

@Suite
struct OverlayGeometryTests {
    @Test
    func testResizeHandleStaysInsideEachScreenEdgeAtEverySupportedScale() {
        let displays = [
            CGRect(x: 0, y: 25, width: 1512, height: 920),
            CGRect(x: -1280, y: 0, width: 1280, height: 760)
        ]
        let scales: [CGFloat] = [0.10, 0.72, 1.8]

        for visibleFrame in displays {
            for scale in scales {
                let proposals = [
                    CGPoint(x: visibleFrame.minX, y: visibleFrame.minY),
                    CGPoint(x: visibleFrame.maxX, y: visibleFrame.minY),
                    CGPoint(x: visibleFrame.minX, y: visibleFrame.maxY),
                    CGPoint(x: visibleFrame.maxX, y: visibleFrame.maxY)
                ]

                for proposal in proposals {
                    let center = OverlayGeometry.clampedPetScreenCenter(
                        proposal,
                        scale: scale,
                        visibleFrame: visibleFrame,
                        clickMenuEnabled: true
                    )
                    let bounds = OverlayGeometry.petInteractiveScreenBounds(
                        scale: scale,
                        petScreenCenter: center,
                        clickMenuEnabled: true,
                        includeResize: true
                    )
                    #expect(
                        visibleFrame.insetBy(dx: -0.5, dy: -0.5).contains(bounds),
                        "interactive bounds \(bounds) escaped \(visibleFrame) at scale \(scale)"
                    )
                }
            }
        }
    }

    @Test
    func testClampIncludesShadowMenuAndResizeHitTarget() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let center = OverlayGeometry.clampedPetScreenCenter(
            CGPoint(x: visibleFrame.maxX, y: visibleFrame.minY),
            scale: 0.72,
            visibleFrame: visibleFrame,
            clickMenuEnabled: true
        )

        let completeBounds = OverlayGeometry.petInteractiveScreenBounds(
            scale: 0.72,
            petScreenCenter: center,
            clickMenuEnabled: true,
            includeResize: true
        )
        let resizeBounds = OverlayGeometry.rect(
            center: OverlayGeometry.resizeScreenCenter(petScreenCenter: center, scale: 0.72),
            size: OverlayGeometry.resizeHitSize
        )
        let menuBounds = OverlayGeometry.rect(
            center: OverlayGeometry.menuScreenCenter(petScreenCenter: center, scale: 0.72),
            size: OverlayGeometry.menuHitSize
        )

        #expect(completeBounds.contains(resizeBounds))
        #expect(completeBounds.contains(menuBounds))
        #expect(visibleFrame.insetBy(dx: -0.5, dy: -0.5).contains(completeBounds))
    }

    @Test
    func testDragCanCrossBetweenDisplaysUsingCurrentPointer() {
        let primary = OverlayDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 875),
            backingScaleFactor: 2
        )
        let secondary = OverlayDisplayGeometry(
            frame: CGRect(x: -1280, y: 0, width: 1280, height: 800),
            visibleFrame: CGRect(x: -1280, y: 0, width: 1280, height: 775),
            backingScaleFactor: 1
        )

        let target = OverlayGeometry.dragTargetDisplay(
            pointer: CGPoint(x: -640, y: 400),
            proposedPetCenter: CGPoint(x: 20, y: 400),
            displays: [primary, secondary],
            fallback: primary
        )

        #expect(target == secondary)
    }

    @Test
    func testKeyboardResizeClampsScale() {
        #expect(OverlayGeometry.clampedScale(0.05) == OverlayGeometry.minimumScale)
        #expect(OverlayGeometry.clampedScale(4) == OverlayGeometry.maximumScale)
        #expect(abs(OverlayGeometry.clampedScale(0.72 + OverlayGeometry.resizeStep) - 0.77) < 0.0001)
    }

    @Test
    func testScalePercentageIgnoresFocusAndRequiresResizeFeedback() {
        #expect(!OverlayScaleFeedbackVisibility.isVisible(
            isFocused: false,
            isResizing: false,
            isStepFeedbackVisible: false
        ))
        #expect(!OverlayScaleFeedbackVisibility.isVisible(
            isFocused: true,
            isResizing: false,
            isStepFeedbackVisible: false
        ))
        #expect(OverlayScaleFeedbackVisibility.isVisible(
            isFocused: false,
            isResizing: true,
            isStepFeedbackVisible: false
        ))
        #expect(OverlayScaleFeedbackVisibility.isVisible(
            isFocused: true,
            isResizing: false,
            isStepFeedbackVisible: true
        ))
    }

    @Test
    func testCalibratedScaleOnlyAppliesToNeverPositionedPlacement() {
        #expect(
            OverlayGeometry.resolvedInitialScale(
                persistedScale: 0.12,
                hasPersistedPosition: false
            ) == 0.72
        )
        #expect(
            OverlayGeometry.resolvedInitialScale(
                persistedScale: 0.12,
                hasPersistedPosition: true
            ) == 0.12
        )
        #expect(
            OverlayGeometry.resolvedInitialScale(
                persistedScale: 0.82,
                hasPersistedPosition: true
            ) == 0.82
        )
    }

    @MainActor
    @Test
    func testResizeViewSupportsKeyboardAndAccessibilityIncrement() {
        let view = OverlayResizeAccessibilityView(frame: CGRect(x: 0, y: 0, width: 38, height: 38))
        var steps: [CGFloat] = []
        view.scale = 0.72
        view.onScaleStep = { steps.append($0) }

        #expect(view.acceptsFirstResponder)
        #expect(view.accessibilityRole() == .slider)
        #expect(view.accessibilityPerformIncrement())
        #expect(view.accessibilityPerformDecrement())
        #expect(steps == [0.05, -0.05])
        let accessibilityScale = (view.accessibilityValue() as? NSNumber)?.doubleValue ?? -1
        #expect(abs(accessibilityScale - 0.72) < 0.0001)
    }
}
