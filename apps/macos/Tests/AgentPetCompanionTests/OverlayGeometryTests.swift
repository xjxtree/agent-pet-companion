import AppKit
import Testing
@testable import AgentPetCompanion

@Suite
struct OverlayGeometryTests {
    @Test
    func testPetMenuOpensOnlyForEnabledRightClick() {
        #expect(!OverlayPetMenuPolicy.shouldOpen(buttonNumber: 0, isEnabled: true))
        #expect(OverlayPetMenuPolicy.shouldOpen(buttonNumber: 1, isEnabled: true))
        #expect(!OverlayPetMenuPolicy.shouldOpen(buttonNumber: 1, isEnabled: false))
        #expect(!OverlayPetMenuPolicy.shouldOpen(buttonNumber: 2, isEnabled: true))
    }

    @Test
    func testCompactOverlayMetricsKeepTwoLineMessagesAndAccessibleControls() {
        #expect(OverlayGeometry.bubbleDetailLineLimit == 2)
        #expect(OverlayGeometry.bubbleWidth == 344)
        #expect(OverlayGeometry.bubbleGap <= 3)
        #expect(OverlayGeometry.menuHitSize.width >= 36)
        #expect(OverlayGeometry.menuHitSize.height >= 36)
        #expect(OverlayGeometry.resizeHitSize.width >= 38)
        #expect(OverlayGeometry.resizeHitSize.height >= 38)
        #expect(OverlayGeometry.menuVisualSize.width < OverlayGeometry.menuHitSize.width)
        #expect(OverlayGeometry.resizeVisualSize.width < OverlayGeometry.resizeHitSize.width)
    }

    @Test
    func testResizeHandleUsesTheSameRightSideControlColumnAsBubbleToggle() {
        let petCenter = CGPoint(x: 420, y: 360)

        for scale in [OverlayGeometry.minimumScale, 0.72, OverlayGeometry.maximumScale] {
            let resizeCenter = OverlayGeometry.resizeCenter(petCenter: petCenter, scale: scale)
            let menuCenter = OverlayGeometry.menuCenter(petCenter: petCenter, scale: scale)
            let resizeRect = OverlayGeometry.rect(center: resizeCenter, size: OverlayGeometry.resizeHitSize)
            let menuRect = OverlayGeometry.rect(center: menuCenter, size: OverlayGeometry.menuHitSize)

            #expect(abs(resizeCenter.x - menuCenter.x) < 0.001)
            #expect(resizeCenter.y > petCenter.y)
            #expect(!resizeRect.intersects(menuRect))

            let screenResizeCenter = OverlayGeometry.resizeScreenCenter(
                petScreenCenter: petCenter,
                scale: scale
            )
            let screenMenuCenter = OverlayGeometry.menuScreenCenter(
                petScreenCenter: petCenter,
                scale: scale
            )
            #expect(abs(screenResizeCenter.x - screenMenuCenter.x) < 0.001)
            #expect(abs((screenResizeCenter.y - petCenter.y) + (resizeCenter.y - petCenter.y)) < 0.001)
        }

        let defaultResizeCenter = OverlayGeometry.resizeCenter(petCenter: petCenter, scale: 0.72)
        let defaultPetSize = OverlayGeometry.petVisibleSize(scale: 0.72)
        #expect(defaultResizeCenter.y < petCenter.y + defaultPetSize.height / 2)
    }

    @Test
    func testCompactControlsPreactivateMouseAndStayClearOfBubblePanel() {
        let scale: CGFloat = 0.72
        let petCenter = CGPoint(x: 900, y: 420)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 934)
        let bubbleSize = CGSize(width: OverlayGeometry.bubbleWidth, height: 76)
        let bubbleCenter = OverlayGeometry.bubbleScreenCenter(
            bubbleSize: bubbleSize,
            scale: scale,
            petScreenCenter: petCenter,
            screenFrame: visibleFrame
        )
        let bubbleRect = OverlayGeometry.rect(center: bubbleCenter, size: bubbleSize)
        let menuRect = OverlayGeometry.rect(
            center: OverlayGeometry.menuScreenCenter(petScreenCenter: petCenter, scale: scale),
            size: OverlayGeometry.menuHitSize
        )
        let resizeRect = OverlayGeometry.rect(
            center: OverlayGeometry.resizeScreenCenter(petScreenCenter: petCenter, scale: scale),
            size: OverlayGeometry.resizeHitSize
        )
        let activationRect = OverlayGeometry.pointerNearPetScreenRect(
            scale: scale,
            petScreenCenter: petCenter,
            clickMenuEnabled: true
        )

        #expect(!bubbleRect.intersects(menuRect))
        #expect(activationRect.contains(menuRect.insetBy(dx: -8, dy: -8)))
        #expect(activationRect.contains(resizeRect.insetBy(dx: -8, dy: -8)))

        let petTop = petCenter.y + OverlayGeometry.petVisualVerticalOffsets(
            scale: scale,
            envelope: nil
        ).top
        #expect(abs(bubbleRect.minY - (petTop + OverlayGeometry.bubbleGap)) < 0.001)
    }

    @Test
    func testBubbleTracksScaledVisiblePetTopForDifferentActionEnvelopes() {
        let petCenter = CGPoint(x: 900, y: 420)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 934)
        let bubbleSize = CGSize(width: 344, height: 76)
        let shortAction = OverlayPetVisualEnvelope(
            canvasSize: CGSize(width: 384, height: 416),
            visibleBounds: CGRect(x: 60, y: 30, width: 264, height: 270)
        )
        let tallAction = OverlayPetVisualEnvelope(
            canvasSize: CGSize(width: 384, height: 416),
            visibleBounds: CGRect(x: 48, y: 24, width: 288, height: 360)
        )

        func bubbleBottom(scale: CGFloat, envelope: OverlayPetVisualEnvelope) -> CGFloat {
            let center = OverlayGeometry.bubbleScreenCenter(
                bubbleSize: bubbleSize,
                scale: scale,
                petScreenCenter: petCenter,
                screenFrame: visibleFrame,
                petVisualEnvelope: envelope
            )
            return center.y - bubbleSize.height / 2
        }

        for scale in [0.25, 0.72, 1.2] {
            let offsets = OverlayGeometry.petVisualVerticalOffsets(
                scale: scale,
                envelope: tallAction
            )
            let bubbleCenter = OverlayGeometry.bubbleScreenCenter(
                bubbleSize: bubbleSize,
                scale: scale,
                petScreenCenter: petCenter,
                screenFrame: visibleFrame,
                petVisualEnvelope: tallAction
            )
            let bubbleRect = OverlayGeometry.rect(center: bubbleCenter, size: bubbleSize)
            let menuRect = OverlayGeometry.rect(
                center: OverlayGeometry.menuScreenCenter(
                    petScreenCenter: petCenter,
                    scale: scale,
                    petVisualEnvelope: tallAction
                ),
                size: OverlayGeometry.menuHitSize
            )
            #expect(abs(
                bubbleBottom(scale: scale, envelope: tallAction)
                    - (petCenter.y + offsets.top + OverlayGeometry.bubbleGap)
            ) < 0.001)
            #expect(!bubbleRect.intersects(menuRect))
            #expect(bubbleRect.minY - menuRect.maxY >= OverlayGeometry.bubbleGap)
            #expect(
                bubbleBottom(scale: scale, envelope: tallAction)
                    > bubbleBottom(scale: scale, envelope: shortAction)
            )
        }

        let smallOffset = bubbleBottom(scale: 0.25, envelope: tallAction) - petCenter.y
        let largeOffset = bubbleBottom(scale: 1.0, envelope: tallAction) - petCenter.y
        #expect(largeOffset > smallOffset)
    }

    @Test
    func testBubblePrefersPetTopEvenWhenBothVerticalSidesFit() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 934)
        let petCenter = CGPoint(x: 900, y: 650)
        let bubbleSize = CGSize(width: 344, height: 117)
        let envelope = OverlayPetVisualEnvelope(
            canvasSize: CGSize(width: 192, height: 208),
            visibleBounds: CGRect(x: 14, y: 31, width: 174, height: 142)
        )
        let petTop = petCenter.y + OverlayGeometry.petVisualVerticalOffsets(
            scale: 1.8,
            envelope: envelope
        ).top
        let bubbleCenter = OverlayGeometry.bubbleScreenCenter(
            bubbleSize: bubbleSize,
            scale: 1.8,
            petScreenCenter: petCenter,
            screenFrame: visibleFrame,
            petVisualEnvelope: envelope
        )
        let bubbleRect = OverlayGeometry.rect(center: bubbleCenter, size: bubbleSize)

        #expect(abs(bubbleRect.minY - (petTop + OverlayGeometry.bubbleGap)) < 0.001)
    }

    @Test
    func testSideControlsTrackVisiblePetRightEdgeInsteadOfTransparentCanvas() {
        let petCenter = CGPoint(x: 700, y: 420)
        let envelope = OverlayPetVisualEnvelope(
            canvasSize: CGSize(width: 384, height: 416),
            visibleBounds: CGRect(x: 54, y: 20, width: 252, height: 370)
        )

        for scale in [0.25, 0.72, 1.8] {
            let fallbackMenu = OverlayGeometry.menuScreenCenter(
                petScreenCenter: petCenter,
                scale: scale
            )
            let fittedMenu = OverlayGeometry.menuScreenCenter(
                petScreenCenter: petCenter,
                scale: scale,
                petVisualEnvelope: envelope
            )
            let fittedResize = OverlayGeometry.resizeScreenCenter(
                petScreenCenter: petCenter,
                scale: scale,
                petVisualEnvelope: envelope
            )

            #expect(fittedMenu.x < fallbackMenu.x)
            #expect(abs(fittedMenu.x - fittedResize.x) < 0.001)
        }

        let smallInset = OverlayGeometry.menuScreenCenter(
            petScreenCenter: petCenter,
            scale: 0.25
        ).x - OverlayGeometry.menuScreenCenter(
            petScreenCenter: petCenter,
            scale: 0.25,
            petVisualEnvelope: envelope
        ).x
        let largeInset = OverlayGeometry.menuScreenCenter(
            petScreenCenter: petCenter,
            scale: 1.8
        ).x - OverlayGeometry.menuScreenCenter(
            petScreenCenter: petCenter,
            scale: 1.8,
            petVisualEnvelope: envelope
        ).x
        #expect(largeInset > smallInset)
    }

    @Test
    func testPetAndControlsStayInsideEachMovementEdgeAtEverySupportedScale() {
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
                    let bounds = OverlayGeometry.petMovementScreenBounds(
                        scale: scale,
                        petScreenCenter: center,
                        clickMenuEnabled: true,
                        includeResize: true
                    )
                    #expect(
                        visibleFrame.insetBy(dx: -0.5, dy: -0.5).contains(bounds),
                        "movement bounds \(bounds) escaped \(visibleFrame) at scale \(scale)"
                    )
                }
            }
        }
    }

    @Test
    func testClampIncludesVisiblePetMenuAndResizeHitTarget() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let center = OverlayGeometry.clampedPetScreenCenter(
            CGPoint(x: visibleFrame.maxX, y: visibleFrame.minY),
            scale: 0.72,
            visibleFrame: visibleFrame,
            clickMenuEnabled: true
        )

        let completeBounds = OverlayGeometry.petMovementScreenBounds(
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
    func testMovementFrameAllowsDockAreaButProtectsMenuBar() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let visibleFrame = CGRect(x: 0, y: 60, width: 1728, height: 1024)

        let movementFrame = OverlayGeometry.petMovementFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        #expect(movementFrame.minX == screenFrame.minX)
        #expect(movementFrame.maxX == screenFrame.maxX)
        #expect(movementFrame.minY == screenFrame.minY)
        #expect(movementFrame.maxY == visibleFrame.maxY)
    }

    @Test
    func testBottomClampUsesActualPetPixelsInsteadOfTransparentCanvas() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let visibleFrame = CGRect(x: 0, y: 60, width: 1728, height: 1024)
        let movementFrame = OverlayGeometry.petMovementFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )
        let envelope = OverlayPetVisualEnvelope(
            canvasSize: CGSize(width: 384, height: 416),
            visibleBounds: CGRect(x: 54, y: 74, width: 270, height: 286)
        )

        let center = OverlayGeometry.clampedPetScreenCenter(
            CGPoint(x: 900, y: -1_000),
            scale: 0.87,
            visibleFrame: movementFrame,
            clickMenuEnabled: true,
            petVisualEnvelope: envelope
        )
        let movementBounds = OverlayGeometry.petMovementScreenBounds(
            scale: 0.87,
            petScreenCenter: center,
            clickMenuEnabled: true,
            includeResize: true,
            petVisualEnvelope: envelope
        )
        let oldVisibleFrameCenter = OverlayGeometry.clampedPetScreenCenter(
            CGPoint(x: 900, y: -1_000),
            scale: 0.87,
            visibleFrame: visibleFrame,
            clickMenuEnabled: true
        )

        #expect(abs(movementBounds.minY - 1) < 0.001)
        #expect(center.y < oldVisibleFrameCenter.y - 50)
    }

    @Test
    func testActualPetEnvelopeClampsEveryEdgeAcrossDisplayLayouts() {
        let displays = [
            OverlayDisplayGeometry(
                frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                visibleFrame: CGRect(x: 0, y: 60, width: 1728, height: 1024),
                backingScaleFactor: 2
            ),
            OverlayDisplayGeometry(
                frame: CGRect(x: -1440, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: -1370, y: 0, width: 1370, height: 875),
                backingScaleFactor: 1
            )
        ]
        let envelope = OverlayPetVisualEnvelope(
            canvasSize: CGSize(width: 384, height: 416),
            visibleBounds: CGRect(x: 42, y: 58, width: 286, height: 318)
        )

        for display in displays {
            let movementFrame = OverlayGeometry.petMovementFrame(
                screenFrame: display.frame,
                visibleFrame: display.visibleFrame
            )
            // Bottom and side Dock reservations are traversable; only the
            // menu-bar strip at the top remains protected.
            #expect(movementFrame.minX == display.frame.minX)
            #expect(movementFrame.maxX == display.frame.maxX)
            #expect(movementFrame.minY == display.frame.minY)
            #expect(movementFrame.maxY == display.visibleFrame.maxY)

            for scale in [OverlayGeometry.minimumScale, 0.72, OverlayGeometry.maximumScale] {
                let proposals = [
                    CGPoint(x: movementFrame.minX - 2_000, y: movementFrame.midY),
                    CGPoint(x: movementFrame.maxX + 2_000, y: movementFrame.midY),
                    CGPoint(x: movementFrame.midX, y: movementFrame.minY - 2_000),
                    CGPoint(x: movementFrame.midX, y: movementFrame.maxY + 2_000),
                    CGPoint(x: movementFrame.minX - 2_000, y: movementFrame.minY - 2_000),
                    CGPoint(x: movementFrame.maxX + 2_000, y: movementFrame.maxY + 2_000)
                ]

                for proposal in proposals {
                    let center = OverlayGeometry.clampedPetScreenCenter(
                        proposal,
                        scale: scale,
                        visibleFrame: movementFrame,
                        clickMenuEnabled: true,
                        petVisualEnvelope: envelope
                    )
                    let bounds = OverlayGeometry.petMovementScreenBounds(
                        scale: scale,
                        petScreenCenter: center,
                        clickMenuEnabled: true,
                        includeResize: true,
                        petVisualEnvelope: envelope
                    )
                    #expect(
                        movementFrame.insetBy(dx: -0.5, dy: -0.5).contains(bounds),
                        "actual pet/control bounds \(bounds) escaped \(movementFrame) at scale \(scale)"
                    )
                }
            }
        }
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
