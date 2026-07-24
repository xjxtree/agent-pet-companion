import AppKit
import AgentPetCompanionCore
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
        #expect(OverlayGeometry.menuHitSize.width >= 38)
        #expect(OverlayGeometry.menuHitSize.height >= 38)
        #expect(OverlayGeometry.resizeHitSize.width >= 38)
        #expect(OverlayGeometry.resizeHitSize.height >= 38)
        #expect(OverlayGeometry.menuVisualSize.width == OverlayGeometry.menuVisualSize.height)
        #expect(OverlayGeometry.menuHitSize.width == OverlayGeometry.menuHitSize.height)
        #expect(OverlayGeometry.menuVisualSize.width < OverlayGeometry.menuHitSize.width)
        #expect(OverlayGeometry.resizeVisualSize.width < OverlayGeometry.resizeHitSize.width)
    }

    @Test
    func testResizeContractUsesExactVisualHitRangeAndStepValues() {
        #expect(OverlayGeometry.resizeVisualSize == CGSize(width: 24, height: 24))
        #expect(OverlayGeometry.resizeHitSize == CGSize(width: 38, height: 38))
        #expect(OverlayGeometry.minimumScale == 0.10)
        #expect(OverlayGeometry.maximumScale == 1.80)
        #expect(OverlayGeometry.resizeStep == 0.05)
    }

    @Test
    func testBubbleToggleUsesCountChevronAndVisibilityBySessionCount() {
        #expect(OverlayBubbleTogglePresentation.content(
            sessionCount: 0,
            collapsed: true
        ) == nil)
        #expect(OverlayBubbleTogglePresentation.content(
            sessionCount: 1,
            collapsed: true
        ) == .chevron(systemImage: "chevron.up"))
        #expect(OverlayBubbleTogglePresentation.content(
            sessionCount: 1,
            collapsed: false
        ) == .chevron(systemImage: "chevron.down"))
        #expect(OverlayBubbleTogglePresentation.content(
            sessionCount: 2,
            collapsed: true
        ) == .count(2))
        #expect(OverlayBubbleTogglePresentation.content(
            sessionCount: 12,
            collapsed: false
        ) == .count(12))
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
    func testBroadActivationZoneDoesNotKeepResizeArtworkVisible() {
        let scale: CGFloat = 0.72
        let petCenter = CGPoint(x: 900, y: 420)
        let activationRect = OverlayGeometry.pointerNearPetScreenRect(
            scale: scale,
            petScreenCenter: petCenter,
            clickMenuEnabled: true
        )
        let activationOnlyPoint = CGPoint(
            x: activationRect.minX + 1,
            y: activationRect.maxY - 1
        )

        #expect(activationRect.contains(activationOnlyPoint))
        #expect(!OverlayGeometry.shouldShowControls(
            at: activationOnlyPoint,
            scale: scale,
            petScreenCenter: petCenter,
            clickMenuEnabled: true
        ))
        #expect(OverlayGeometry.shouldShowControls(
            at: petCenter,
            scale: scale,
            petScreenCenter: petCenter,
            clickMenuEnabled: true
        ))
        #expect(OverlayGeometry.shouldShowControls(
            at: OverlayGeometry.resizeScreenCenter(
                petScreenCenter: petCenter,
                scale: scale
            ),
            scale: scale,
            petScreenCenter: petCenter,
            clickMenuEnabled: true
        ))
    }

    @Test
    func testPointerRegionsTrackTheActualPetEnvelope() {
        let scale: CGFloat = 1
        let petCenter = CGPoint(x: 500, y: 400)
        let envelope = OverlayPetVisualEnvelope(
            canvasSize: CGSize(width: 1_000, height: 1_000),
            visibleBounds: CGRect(x: 700, y: 200, width: 120, height: 500)
        )
        let visualRect = OverlayGeometry.petVisualScreenRect(
            scale: scale,
            petScreenCenter: petCenter,
            petVisualEnvelope: envelope
        )
        let resizeCenter = OverlayGeometry.resizeScreenCenter(
            petScreenCenter: petCenter,
            scale: scale,
            petVisualEnvelope: envelope
        )
        let activationRect = OverlayGeometry.pointerNearPetScreenRect(
            scale: scale,
            petScreenCenter: petCenter,
            clickMenuEnabled: true,
            petVisualEnvelope: envelope
        )

        #expect(visualRect.midX > petCenter.x)
        #expect(resizeCenter.x > visualRect.maxX)
        #expect(activationRect.contains(resizeCenter))
        #expect(OverlayGeometry.shouldShowControls(
            at: CGPoint(x: visualRect.midX, y: visualRect.midY),
            scale: scale,
            petScreenCenter: petCenter,
            clickMenuEnabled: true,
            petVisualEnvelope: envelope
        ))
    }

    @Test
    func transparentPixelsInsideThePetDragRegionPassThroughWhileOpaquePixelsHandle() throws {
        let mask = try #require(OverlayPetAlphaMask(
            pixelWidth: 3,
            pixelHeight: 3,
            alphaValuesTopToBottom: [
                255, 255, 255,
                255, 0, 255,
                255, 255, 255,
            ]
        ))
        let hitTest = OverlayPetFrameHitTest(
            canvasSize: CGSize(width: 3, height: 3),
            alphaMask: mask
        )
        let containerSize = CGSize(width: 800, height: 600)
        let petCenter = CGPoint(x: 400, y: 300)
        let panelFrame = CGRect(origin: .zero, size: containerSize)

        func handles(_ point: CGPoint, hitTest candidate: OverlayPetFrameHitTest?) -> Bool {
            OverlayGeometry.shouldHandleMouse(
                atTopLeftPoint: point,
                in: containerSize,
                scale: 1,
                petCenter: petCenter,
                bubbleVisible: false,
                clickMenuEnabled: true,
                panelFrame: panelFrame,
                screenFrame: panelFrame,
                includeBubble: false,
                petFrameHitTest: candidate
            )
        }

        #expect(!handles(petCenter, hitTest: hitTest))
        #expect(handles(CGPoint(x: petCenter.x - 70, y: petCenter.y), hitTest: hitTest))

        // A frame mask is briefly unavailable during launch and state changes.
        // Keep the geometric pet region interactive until pixel data arrives.
        #expect(handles(petCenter, hitTest: nil))
        #expect(handles(
            OverlayGeometry.resizeCenter(petCenter: petCenter, scale: 1),
            hitTest: nil
        ))
        #expect(handles(
            OverlayGeometry.menuCenter(petCenter: petCenter, scale: 1),
            hitTest: nil
        ))
    }

    @Test
    func alphaHitTestingUsesMetalAspectFitScaleAndTopLeftViewConversion() throws {
        let mask = try #require(OverlayPetAlphaMask(
            pixelWidth: 2,
            pixelHeight: 2,
            alphaValuesTopToBottom: [
                255, 0,
                0, 0,
            ]
        ))
        let hitTest = OverlayPetFrameHitTest(
            // Exercise the renderer's horizontal centering for a frame that
            // is narrower than the animation's stable canvas.
            canvasSize: CGSize(width: 4, height: 2),
            alphaMask: mask
        )
        let petCenter = CGPoint(x: 360, y: 280)
        let viewHeight: CGFloat = 700

        func topLeftPointForPixel(x: Int, topRow: Int, scale: CGFloat) -> CGPoint {
            let drawableSize = CGSize(width: 230 * scale, height: 310 * scale)
            let fittedScale = min(drawableSize.width / 4, drawableSize.height / 2)
            let fittedOrigin = CGPoint(
                x: (drawableSize.width - 4 * fittedScale) / 2,
                y: (drawableSize.height - 2 * fittedScale) / 2
            )
            let bottomRow = 1 - topRow
            let localBottomLeft = CGPoint(
                x: fittedOrigin.x + (1 + CGFloat(x) + 0.5) * fittedScale,
                y: fittedOrigin.y + (CGFloat(bottomRow) + 0.5) * fittedScale
            )
            return CGPoint(
                x: petCenter.x - drawableSize.width / 2 + localBottomLeft.x,
                y: petCenter.y + drawableSize.height / 2 - localBottomLeft.y
            )
        }

        for scale in [CGFloat(0.25), CGFloat(1.8)] {
            let opaqueTopLeft = topLeftPointForPixel(x: 0, topRow: 0, scale: scale)
            let transparentBottomLeft = topLeftPointForPixel(x: 0, topRow: 1, scale: scale)

            #expect(OverlayGeometry.petFrameContainsOpaquePixel(
                atTopLeftPoint: opaqueTopLeft,
                scale: scale,
                petCenter: petCenter,
                frameHitTest: hitTest
            ))
            #expect(!OverlayGeometry.petFrameContainsOpaquePixel(
                atTopLeftPoint: transparentBottomLeft,
                scale: scale,
                petCenter: petCenter,
                frameHitTest: hitTest
            ))

            let flippedPoint = OverlayGeometry.topLeftPoint(
                forViewPoint: opaqueTopLeft,
                in: viewHeight,
                isFlipped: true
            )
            let unflippedPoint = OverlayGeometry.topLeftPoint(
                forViewPoint: CGPoint(
                    x: opaqueTopLeft.x,
                    y: viewHeight - opaqueTopLeft.y
                ),
                in: viewHeight,
                isFlipped: false
            )
            #expect(flippedPoint == opaqueTopLeft)
            #expect(unflippedPoint == opaqueTopLeft)
        }
    }

    @Test
    func disablingMousePassthroughRestoresWholePanelHitTesting() throws {
        let transparentMask = try #require(OverlayPetAlphaMask(
            pixelWidth: 1,
            pixelHeight: 1,
            alphaValuesTopToBottom: [0]
        ))
        let containerSize = CGSize(width: 800, height: 600)
        let panelFrame = CGRect(origin: .zero, size: containerSize)

        #expect(OverlayGeometry.shouldHandleMouse(
            atTopLeftPoint: CGPoint(x: 40, y: 40),
            in: containerSize,
            scale: 1,
            petCenter: CGPoint(x: 400, y: 300),
            bubbleVisible: false,
            clickMenuEnabled: false,
            panelFrame: panelFrame,
            screenFrame: panelFrame,
            includeBubble: false,
            mousePassthroughEnabled: false,
            petFrameHitTest: OverlayPetFrameHitTest(
                canvasSize: CGSize(width: 1, height: 1),
                alphaMask: transparentMask
            )
        ))
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
        #expect(OverlayGeometry.clampedScale(0.10) == 0.10)
        #expect(OverlayGeometry.clampedScale(1.80) == 1.80)
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
    func testResizeControlHidesOutsidePetUnlessInteractionIsActive() {
        #expect(!OverlayControlVisibility.isVisible(
            pointerNearPet: false,
            petDragInProgress: false,
            resizeInProgress: false
        ))
        #expect(OverlayControlVisibility.isVisible(
            pointerNearPet: true,
            petDragInProgress: false,
            resizeInProgress: false
        ))
        #expect(OverlayControlVisibility.isVisible(
            pointerNearPet: false,
            petDragInProgress: true,
            resizeInProgress: false
        ))
        #expect(OverlayControlVisibility.isVisible(
            pointerNearPet: false,
            petDragInProgress: false,
            resizeInProgress: true
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
        let view = OverlayResizeAccessibilityView(
            frame: CGRect(origin: .zero, size: OverlayGeometry.resizeHitSize)
        )
        var steps: [CGFloat] = []
        view.scale = 0.72
        view.onScaleStep = { steps.append($0) }

        #expect(view.acceptsFirstResponder)
        #expect(view.accessibilityRole() == .slider)
        #expect(view.accessibilityPerformIncrement())
        #expect(view.accessibilityPerformDecrement())
        #expect(steps == [0.05, -0.05])
        #expect((view.accessibilityMinValue() as? NSNumber)?.doubleValue == 0.10)
        #expect((view.accessibilityMaxValue() as? NSNumber)?.doubleValue == 1.80)
        let accessibilityScale = (view.accessibilityValue() as? NSNumber)?.doubleValue ?? -1
        #expect(abs(accessibilityScale - 0.72) < 0.0001)
    }

    @Test
    func petClickAndDragUseOneExclusiveThreshold() {
        #expect(!OverlayPetPointerGesture.exceedsDragThreshold(
            from: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 13, y: 10)
        ))
        #expect(OverlayPetPointerGesture.exceedsDragThreshold(
            from: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 13.1, y: 10)
        ))
    }

    @Test
    func petDragRubberBandsPastEdgesWithoutChangingTheHardReleaseBoundary() {
        let movementFrame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let scale: CGFloat = 0.72
        let inside = CGPoint(x: 600, y: 400)
        #expect(OverlayPetDragMotion.rubberBandedCenter(
            inside,
            scale: scale,
            visibleFrame: movementFrame
        ) == inside)

        let proposed = CGPoint(x: -600, y: 1_200)
        let hard = OverlayGeometry.clampedPetScreenCenter(
            proposed,
            scale: scale,
            visibleFrame: movementFrame
        )
        let presentation = OverlayPetDragMotion.rubberBandedCenter(
            proposed,
            scale: scale,
            visibleFrame: movementFrame
        )

        #expect(presentation.x < hard.x)
        #expect(presentation.x > proposed.x)
        #expect(presentation.y > hard.y)
        #expect(presentation.y < proposed.y)
        #expect(abs(presentation.x - hard.x) < 64 * scale)
        #expect(abs(presentation.y - hard.y) < 64 * scale)
    }

    @Test
    func petReleaseUsesBoundedRecentVelocityAndCriticallyDampedSettling() {
        let samples = [
            OverlayPetMotionSample(
                point: CGPoint(x: 0, y: 0),
                timestamp: 1
            ),
            OverlayPetMotionSample(
                point: CGPoint(x: 100, y: 0),
                timestamp: 1.05
            ),
            OverlayPetMotionSample(
                point: CGPoint(x: 240, y: 0),
                timestamp: 1.10
            ),
        ]
        let velocity = OverlayPetDragMotion.estimatedVelocity(from: samples)
        #expect(abs(hypot(velocity.dx, velocity.dy) - 1_200) < 0.001)

        let movementFrame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let start = CGPoint(x: 500, y: 400)
        let target = OverlayPetDragMotion.projectedReleaseTarget(
            from: start,
            velocity: velocity,
            scale: 0.72,
            visibleFrame: movementFrame
        )
        #expect(target.x > start.x)

        let initial = OverlayPetDragMotion.criticallyDampedPosition(
            from: start,
            to: target,
            initialVelocity: velocity,
            elapsed: 0
        )
        let moving = OverlayPetDragMotion.criticallyDampedPosition(
            from: start,
            to: target,
            initialVelocity: velocity,
            elapsed: 0.04
        )
        let settled = OverlayPetDragMotion.criticallyDampedPosition(
            from: start,
            to: target,
            initialVelocity: velocity,
            elapsed: OverlayPetDragMotion.releaseSettlingDuration
        )

        #expect(initial == start)
        #expect(moving.x > start.x)
        #expect(hypot(settled.x - target.x, settled.y - target.y) < 1)
    }

    @Test
    func petActivationPrioritizesOpenSessionThenBubbleThenControlCenter() {
        let openSession = OverlaySessionContent(
            id: "session-open",
            source: .codex,
            sessionID: "s1",
            eventType: .tool,
            sessionTitle: "Session",
            messageText: "Working",
            statusText: "",
            navigation: AgentSessionNavigation(
                capability: .agentHost,
                sessionOpen: true,
                surface: "chatgpt_app"
            )
        )
        var closedSession = openSession
        closedSession.navigation.sessionOpen = false

        #expect(OverlayPetActivationDestination.resolve(
            activeSession: openSession,
            bubbleDismissed: true,
            hasAvailableBubbleContent: true
        ) == .session(openSession))
        #expect(OverlayPetActivationDestination.resolve(
            activeSession: closedSession,
            bubbleDismissed: true,
            hasAvailableBubbleContent: true
        ) == .bubble)
        #expect(OverlayPetActivationDestination.resolve(
            activeSession: closedSession,
            bubbleDismissed: false,
            hasAvailableBubbleContent: true
        ) == .bubble)
        #expect(OverlayPetActivationDestination.resolve(
            activeSession: closedSession,
            bubbleDismissed: false,
            hasAvailableBubbleContent: false
        ) == .controlCenter)
        #expect(OverlayPetActivationDestination.resolve(
            activeSession: nil,
            bubbleDismissed: true,
            hasAvailableBubbleContent: true
        ) == .controlCenter)
    }

    @MainActor
    @Test
    func petDragViewExposesAccessibilityDefaultAction() {
        let view = WindowDragRegion.DragView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        var activationCount = 0
        view.onActivate = { activationCount += 1 }

        #expect(view.accessibilityRole() == .button)
        #expect(view.accessibilityPerformPress())
        #expect(activationCount == 1)
    }

    @Test
    func overlayControlsFadeInImmediatelyAndDelayOnlyPointerExit() {
        #expect(OverlayControlVisibility.transitionDelay(showing: true, forced: false)
            == .zero)
        #expect(OverlayControlVisibility.transitionDelay(showing: false, forced: false)
            == .milliseconds(300))
        #expect(OverlayControlVisibility.transitionDelay(showing: true, forced: true) == .zero)
        #expect(OverlayControlVisibility.isVisible(
            pointerNearPet: false,
            petDragInProgress: false,
            resizeInProgress: false,
            keyboardFocusActive: true
        ))
        #expect((0.12 ... 0.16).contains(OverlayMotion.controlFadeDuration))
        #expect(OverlayMotion.controlFadeDelay == .milliseconds(140))
        #expect((0.18 ... 0.22).contains(OverlayMotion.bubbleLayoutDuration))
        #expect(OverlayMotion.reducedMotionCrossfadeDuration > 0)
        #expect(OverlayMotion.reducedMotionCrossfadeDuration <= 0.22)
    }

    @Test
    func overlayContentUsesDisplayFieldsAndIgnoresRawEventPayload() throws {
        let displayTitle = "修复宠物消息气泡"
        let displayReply = "气泡已经恢复显示最新回复。"
        let rawPrompt = "RAW_EVENT_PROMPT_DO_NOT_RENDER sk-live-secret /Users/alice/private.txt"
        let rawCommand = "COMMAND_DO_NOT_RENDER /bin/sh -c curl-secret"
        let json = """
        {
          "state":"tool",
          "official_status":"running",
          "source":"codex",
          "session_id":"safe-session",
          "session_active":true,
          "source_session_sequence":3,
          "priority":300,
          "lease_seconds":null,
          "expires_at":null,
          "event":{
            "id":"safe-event",
            "source":"codex",
            "session_id":"safe-session",
            "event_type":"tool",
            "title":"执行工具",
            "detail":null,
            "payload_json":{
              "message_role":"assistant",
              "message_content":"\(rawPrompt)",
              "activity_kind":"command",
              "activity_content":"\(rawCommand)",
              "project_label":"/Users/alice/private"
            },
            "created_at":"2026-07-21T00:00:00Z"
          },
          "latest_message":{
            "id":"raw-message",
            "source":"codex",
            "session_id":"safe-session",
            "event_type":"review",
            "title":"待查看",
            "detail":null,
            "payload_json":{"message_role":"assistant","message_content":"\(rawPrompt)"},
            "created_at":"2026-07-21T00:00:00Z"
          },
          "session_title":"\(displayTitle)",
          "session_user_message":{"role":"user","content":"\(displayTitle)"},
          "session_message":{"role":"assistant","content":"\(displayReply)"},
          "session_activity":{"kind":"command","content":"\(rawCommand)"},
          "overlay_display":{
            "summary_kind":"command",
            "navigation":{
              "session_open":true,
              "surface":"cli_terminal",
              "terminal_app":"terminal",
              "open_url":null
            }
          }
        }
        """
        let state = try JSONDecoder().decode(
            ActiveAgentState.self,
            from: Data(json.utf8)
        )
        let content = OverlaySessionContent(state: state)

        #expect(content.sessionID == "safe-session")
        #expect(content.sessionTitle == displayTitle)
        #expect(content.messageText == displayReply)
        #expect(content.navigation.sessionOpen == true)
        #expect(!content.sessionTitle.contains(rawPrompt))
        #expect(!content.messageText.contains(rawPrompt))
        #expect(!content.messageText.contains(rawCommand))
    }

    @Test
    func legacyStateNeverFallsBackToRawEventPayload() throws {
        let state = try JSONDecoder().decode(
            ActiveAgentState.self,
            from: Data(#"{"state":"review","official_status":"ready","source":"pi","session_id":"legacy","session_active":false,"source_session_sequence":1,"priority":400,"lease_seconds":30,"expires_at":null,"event":{"id":"legacy-review","source":"pi","session_id":"legacy","event_type":"review","title":"待查看","detail":null,"payload_json":{"message_role":"assistant","message_content":"PRIVATE_RESULT_DO_NOT_RENDER"},"created_at":"2026-07-21T00:00:00Z"}}"#.utf8)
        )
        let content = OverlaySessionContent(state: state)

        #expect(content.messageText == APCLocalization.text(.overlayDetailReady))
        #expect(content.sessionTitle == APCLocalization.format(.overlaySessionTitleFormat, "Pi"))
        #expect(!content.sessionTitle.contains("PRIVATE"))
        #expect(!content.messageText.contains("PRIVATE"))
    }

    @Test
    func omittedSessionSummaryIsBoundedAndOpensTheControlCenterPath() {
        let content = OverlayBubbleContent.omittedSummary(count: 5)
        let accessibility = OverlayBubbleAccessibilityModel(content: content, locale: "en")

        #expect(content.sessions.count == 1)
        #expect(content.representedSessionCount == 5)
        #expect(content.isOmittedSummary)
        #expect(!content.canDismiss)
        #expect(content.sessions[0].source == nil)
        #expect(content.sessions[0].canOpen)
        #expect(content.sessions[0].messageText == APCLocalization.format(
            .overlayMoreSessionsDetailFormat,
            5
        ))
        #expect(accessibility.sessionActionLabels == ["Open"])
        #expect(accessibility.sessionCloseActionLabels == [nil])
        #expect(accessibility.closeActionLabel == nil)
    }

    @Test
    func bubbleAccessibilityModelOffersLocalizedSessionCloseAndGroupActions() {
        let sessionA = OverlaySessionContent(
            id: "a",
            source: .codex,
            sessionID: "a",
            eventType: .tool,
            sessionTitle: "A",
            messageText: "A",
            statusText: "",
            navigation: AgentSessionNavigation(
                capability: .agentHost,
                sessionOpen: true,
                surface: "chatgpt_app"
            )
        )
        let sessionB = OverlaySessionContent(
            id: "b",
            source: .codex,
            sessionID: "b",
            eventType: .review,
            sessionTitle: "B",
            messageText: "B",
            statusText: "",
            navigation: AgentSessionNavigation(
                capability: .agentHost,
                sessionOpen: true,
                surface: "chatgpt_app"
            )
        )
        let content = OverlayBubbleContent(
            id: "codex",
            source: .codex,
            agentName: "Codex",
            sessions: [sessionA, sessionB],
            isExpanded: true
        )
        let english = OverlayBubbleAccessibilityModel(content: content, locale: "en")
        let chinese = OverlayBubbleAccessibilityModel(content: content, locale: "zh-Hans")

        #expect(english.sessionActionLabels == ["Open Codex", "Open Codex"])
        #expect(english.sessionCloseActionLabels == ["Hide This Session", "Hide This Session"])
        #expect(english.closeActionLabel == "Close session bubble")
        #expect(english.groupActionLabel == "Collapse 2 sessions")
        #expect(chinese.sessionActionLabels == ["打开 Codex", "打开 Codex"])
        #expect(chinese.sessionCloseActionLabels == ["收起此会话", "收起此会话"])
        #expect(chinese.closeActionLabel == "关闭会话气泡")
        #expect(chinese.groupActionLabel == "收起 2 个会话")
    }

    @Test
    func voiceOverReadingOrderKeepsLongEnglishAndChineseSessionCopySemantic() {
        let fixtures = [
            (
                session: "A longer session title that still identifies the active work",
                status: "Needs You",
                message: "Return to the agent to approve, answer, or decide."
            ),
            (
                session: "一个用于确认较长中文内容仍保持语义顺序的会话标题",
                status: "等你处理",
                message: "请回到 Agent 完成确认、回答或决策。"
            ),
        ]

        for fixture in fixtures {
            let session = OverlaySessionContent(
                id: "voiceover-order",
                source: .codex,
                sessionID: "voiceover-order",
                eventType: .waiting,
                sessionTitle: fixture.session,
                messageText: fixture.message,
                statusText: fixture.status,
                navigation: AgentSessionNavigation(
                    capability: .agentHost,
                    sessionOpen: true,
                    surface: "chatgpt_app"
                )
            )

            #expect(session.accessibilityReadingOrder == [
                "Codex",
                fixture.session,
                fixture.status,
                fixture.message,
                session.actionLabel,
            ])
            #expect(
                session.accessibilityLabel
                    == session.accessibilityReadingOrder.joined(separator: ", ")
            )
        }
    }

    @Test
    func collapsedBubbleLayoutKeepsOneStableRowAcrossAttentionChanges() {
        let first = OverlaySessionContent(
            id: "first",
            source: .codex,
            sessionID: "first",
            eventType: .tool,
            sessionTitle: "Codex session 1",
            messageText: "Working",
            statusText: "Working"
        )
        let secondRunning = OverlaySessionContent(
            id: "second",
            source: .codex,
            sessionID: "second",
            eventType: .tool,
            sessionTitle: "Codex session 2",
            messageText: "Working",
            statusText: "Working"
        )
        var secondAttention = secondRunning
        secondAttention.eventType = .waiting
        let collapsedRunning = OverlayBubbleContent(
            id: "agent-codex",
            source: .codex,
            agentName: "Codex",
            sessions: [first, secondRunning],
            isExpanded: false
        )
        let collapsedAttention = OverlayBubbleContent(
            id: "agent-codex",
            source: .codex,
            agentName: "Codex",
            sessions: [first, secondAttention],
            isExpanded: false
        )

        let running = OverlayBubbleLayoutSignature(
            contents: [collapsedRunning],
            bubbleDismissed: false
        )
        let attention = OverlayBubbleLayoutSignature(
            contents: [collapsedAttention],
            bubbleDismissed: false
        )
        let dismissed = OverlayBubbleLayoutSignature(contents: [], bubbleDismissed: true)

        #expect(running.groups[0].visibleSessionCount == 1)
        #expect(attention.groups[0].visibleSessionCount == 1)
        #expect(running == attention)
        #expect(dismissed != attention)
    }

    @MainActor
    @Test
    func sharedControlPresentationStartsHoverImmediatelyAndDelaysExit() async throws {
        var requestedDelays: [Duration] = []
        let presentation = OverlayControlPresentationState { delay in
            requestedDelays.append(delay)
        }

        presentation.setHovered(.pet, true)
        #expect(presentation.isVisible)

        presentation.setHovered(.pet, false)
        #expect(presentation.isVisible)
        for _ in 0 ..< 10 where presentation.isVisible {
            await Task.yield()
        }
        #expect(requestedDelays == [OverlayControlVisibility.hoverHideDelay])
        #expect(!presentation.isVisible)

        presentation.setActive(.resize, true)
        #expect(presentation.isVisible)
        presentation.setActive(.resize, false)
        #expect(presentation.isVisible)

        presentation.setFocused(.bubble, true)
        #expect(presentation.keyboardNavigationActive)
        #expect(presentation.isVisible)
        presentation.setFocused(.bubble, false)
        #expect(!presentation.keyboardNavigationActive)
    }

    @MainActor
    @Test
    func resizeAccessibilityCopyIsLocalizedForEnglishAndChinese() {
        #expect(OverlayResizeAccessibilityView.accessibilityLabel(localeIdentifier: "en")
            == "Display Size")
        #expect(OverlayResizeAccessibilityView.accessibilityLabel(localeIdentifier: "zh-Hans")
            == "显示尺寸")
        #expect(OverlayResizeAccessibilityView.accessibilityHelp(localeIdentifier: "en")
            == "Drag to resize the desktop pet")
        #expect(OverlayResizeAccessibilityView.accessibilityHelp(localeIdentifier: "zh-Hans")
            == "拖拽调整桌宠大小")
    }
}
