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
        #expect(OverlayGeometry.bubbleStandaloneSummaryLineLimit == 2)
        #expect(OverlayGeometry.bubbleWidth == 344)
        #expect(OverlayGeometry.bubbleGap <= 3)
        #expect(OverlayGeometry.menuHitSize.width >= 38)
        #expect(OverlayGeometry.menuHitSize.height >= 38)
        #expect(OverlayGeometry.menuVisualSize.width == OverlayGeometry.menuVisualSize.height)
        #expect(OverlayGeometry.menuHitSize.width == OverlayGeometry.menuHitSize.height)
        #expect(OverlayGeometry.menuVisualSize.width < OverlayGeometry.menuHitSize.width)
    }

    @Test
    func standaloneBubbleHeightAlwaysReservesItsTwoLineMaximum() {
        let sessions = [
            OverlaySessionContent(
                id: "empty",
                source: .codex,
                sessionID: "empty",
                eventType: .thinking,
                sessionTitle: "Investigate bubble",
                messageText: "",
                statusText: ""
            ),
            OverlaySessionContent(
                id: "one-line",
                source: .codex,
                sessionID: "one-line",
                eventType: .thinking,
                sessionTitle: "Investigate bubble",
                messageText: "Thinking",
                statusText: "Thinking"
            ),
            OverlaySessionContent(
                id: "two-lines",
                source: .codex,
                sessionID: "two-lines",
                eventType: .tool,
                sessionTitle: "Investigate bubble",
                messageText: String(repeating: "Bounded two-line session detail ", count: 8),
                statusText: "Running"
            ),
        ]

        for fontScale in BubbleFontScale.allCases {
            let heights = sessions.map { session in
                OverlayGeometry.resolvedBubbleSize(
                    in: CGSize(width: 1_512, height: 934),
                    content: OverlayBubbleContent(
                        id: "standalone-\(session.id)",
                        source: .codex,
                        agentName: "Codex",
                        sessions: [session],
                        isStandaloneSessionCard: true
                    ),
                    fontScale: fontScale
                ).height
            }
            #expect(heights.dropFirst().allSatisfy { $0 == heights[0] })
        }
    }

    @Test
    func displayWidthContractUsesExactRangeAspectAndDefault() {
        #expect(OverlayGeometry.minimumDisplayWidthPt == 100)
        #expect(OverlayGeometry.defaultDisplayWidthPt == 112)
        #expect(OverlayGeometry.maximumDisplayWidthPt == 300)
        let size = OverlayGeometry.petVisibleSize(displayWidthPt: 112)
        #expect(size.width == 112)
        #expect(abs(size.height - 112 * OverlayGeometry.displayAspectHeightRatio) < 0.001)
    }

    @Test
    func bubbleToggleUsesAnAnchorAwareChevronForEverySessionCount() {
        #expect(OverlayBubbleTogglePresentation.content(
            sessionCount: 0,
            revealsMoreContent: true
        ) == nil)
        #expect(OverlayBubbleTogglePresentation.content(
            sessionCount: 1,
            revealsMoreContent: true
        ) == .chevron(systemImage: "chevron.up"))
        #expect(OverlayBubbleTogglePresentation.content(
            sessionCount: 1,
            revealsMoreContent: false
        ) == .chevron(systemImage: "chevron.down"))
        #expect(OverlayBubbleTogglePresentation.content(
            sessionCount: 2,
            revealsMoreContent: true
        ) == .chevron(systemImage: "chevron.up"))
        #expect(OverlayBubbleTogglePresentation.content(
            sessionCount: 12,
            revealsMoreContent: false
        ) == .chevron(systemImage: "chevron.down"))
        #expect(OverlayBubbleTogglePresentation.content(
            sessionCount: 2,
            revealsMoreContent: true,
            anchorDirection: .below
        ) == .chevron(systemImage: "chevron.down"))
        #expect(OverlayBubbleTogglePresentation.content(
            sessionCount: 2,
            revealsMoreContent: false,
            anchorDirection: .below
        ) == .chevron(systemImage: "chevron.up"))
    }

    @Test
    func bubbleToggleMovesOneLevelThroughTheFlatTrayInEitherDirection() {
        #expect(OverlayBubbleDisclosureAction.resolve(
            groupSessionsByAgent: false,
            sessionCount: 2,
            bubbleDismissed: false,
            standaloneStackExpanded: true,
            standaloneStackDirection: .expanding
        ) == .collapseStandaloneStack)
        #expect(OverlayBubbleDisclosureAction.resolve(
            groupSessionsByAgent: false,
            sessionCount: 2,
            bubbleDismissed: false,
            standaloneStackExpanded: false,
            standaloneStackDirection: .collapsing
        ) == .dismissBubble)
        #expect(OverlayBubbleDisclosureAction.resolve(
            groupSessionsByAgent: false,
            sessionCount: 2,
            bubbleDismissed: true,
            standaloneStackExpanded: false,
            standaloneStackDirection: .collapsing
        ) == .revealCollapsedStandaloneStack)
        #expect(OverlayBubbleDisclosureAction.resolve(
            groupSessionsByAgent: false,
            sessionCount: 2,
            bubbleDismissed: false,
            standaloneStackExpanded: false,
            standaloneStackDirection: .expanding
        ) == .expandStandaloneStack)
        #expect(OverlayBubbleDisclosureAction.resolve(
            groupSessionsByAgent: false,
            sessionCount: 1,
            bubbleDismissed: false,
            standaloneStackExpanded: true,
            standaloneStackDirection: .expanding
        ) == .dismissBubble)
        #expect(OverlayBubbleDisclosureAction.resolve(
            groupSessionsByAgent: true,
            sessionCount: 2,
            bubbleDismissed: true,
            standaloneStackExpanded: true,
            standaloneStackDirection: .collapsing
        ) == .revealBubble)
    }

    @Test
    func flatCardsKeepOnePriorityFirstReadingOrderOnEitherSide() {
        func card(_ id: String) -> OverlayBubbleContent {
            OverlayBubbleContent(
                id: id,
                source: .codex,
                agentName: "Codex",
                sessions: [OverlaySessionContent(
                    id: id,
                    source: .codex,
                    sessionID: id,
                    eventType: .tool,
                    sessionTitle: id,
                    messageText: "Summary",
                    statusText: "Running"
                )],
                isStandaloneSessionCard: true
            )
        }

        let contents = [card("priority"), card("older")]
        #expect(OverlayGeometry.visuallyOrderedBubbleContents(
            contents,
            anchorDirection: .above
        ).map(\.id) == ["priority", "older"])
        #expect(OverlayGeometry.visuallyOrderedBubbleContents(
            contents,
            anchorDirection: .below
        ).map(\.id) == ["priority", "older"])

        let grouped = OverlayBubbleContent(
            id: "agent-codex",
            source: .codex,
            agentName: "Codex",
            sessions: contents.flatMap(\.sessions)
        )
        #expect(OverlayGeometry.visuallyOrderedBubbleContents(
            [grouped],
            anchorDirection: .below
        ) == [grouped])
    }

    @Test
    func menuTracksTheRightEdgeAtEverySupportedDisplayWidth() {
        let petCenter = CGPoint(x: 420, y: 360)

        for displayWidthPt in [
            OverlayGeometry.minimumDisplayWidthPt,
            OverlayGeometry.defaultDisplayWidthPt,
            OverlayGeometry.maximumDisplayWidthPt,
        ] {
            let menuCenter = OverlayGeometry.menuCenter(
                petCenter: petCenter,
                displayWidthPt: displayWidthPt
            )
            let petRect = OverlayGeometry.rect(
                center: petCenter,
                size: OverlayGeometry.petVisibleSize(displayWidthPt: displayWidthPt)
            )

            #expect(menuCenter.x > petRect.maxX)
            #expect(abs(menuCenter.x - petRect.maxX - 8) < 0.001)

            let screenMenuCenter = OverlayGeometry.menuScreenCenter(
                petScreenCenter: petCenter,
                displayWidthPt: displayWidthPt
            )
            #expect(abs(screenMenuCenter.x - menuCenter.x) < 0.001)
            #expect(abs((screenMenuCenter.y - petCenter.y)
                + (menuCenter.y - petCenter.y)) < 0.001)
        }
    }

    @Test
    func testCompactControlsStayClearOfBubblePanel() {
        let displayWidthPt: CGFloat = 112
        let petCenter = CGPoint(x: 900, y: 420)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 934)
        let bubbleSize = CGSize(width: OverlayGeometry.bubbleWidth, height: 76)
        let bubbleCenter = OverlayGeometry.bubbleScreenCenter(
            bubbleSize: bubbleSize,
            displayWidthPt: displayWidthPt,
            petScreenCenter: petCenter,
            screenFrame: visibleFrame
        )
        let bubbleRect = OverlayGeometry.rect(center: bubbleCenter, size: bubbleSize)
        let menuRect = OverlayGeometry.rect(
            center: OverlayGeometry.menuScreenCenter(
                petScreenCenter: petCenter,
                displayWidthPt: displayWidthPt
            ),
            size: OverlayGeometry.menuHitSize
        )
        #expect(!bubbleRect.intersects(menuRect))

        let petTop = petCenter.y + OverlayGeometry.petVisualVerticalOffsets(
            displayWidthPt: displayWidthPt,
            envelope: nil
        ).top
        #expect(abs(bubbleRect.minY - (petTop + OverlayGeometry.bubbleGap)) < 0.001)
    }

    @Test
    func controlVisibilityUsesOnlyVisiblePetAndMenuRegions() {
        let displayWidthPt: CGFloat = 112
        let petCenter = CGPoint(x: 900, y: 420)
        let outsidePoint = CGPoint(x: petCenter.x - 100, y: petCenter.y + 100)

        #expect(!OverlayGeometry.shouldShowControls(
            at: outsidePoint,
            displayWidthPt: displayWidthPt,
            petScreenCenter: petCenter,
            clickMenuEnabled: true
        ))
        #expect(OverlayGeometry.shouldShowControls(
            at: petCenter,
            displayWidthPt: displayWidthPt,
            petScreenCenter: petCenter,
            clickMenuEnabled: true
        ))
        #expect(OverlayGeometry.shouldShowControls(
            at: OverlayGeometry.menuScreenCenter(
                petScreenCenter: petCenter,
                displayWidthPt: displayWidthPt
            ),
            displayWidthPt: displayWidthPt,
            petScreenCenter: petCenter,
            clickMenuEnabled: true
        ))
    }

    @Test
    func testPointerRegionsTrackTheActualPetEnvelope() {
        let displayWidthPt: CGFloat = 112
        let petCenter = CGPoint(x: 500, y: 400)
        let envelope = OverlayPetVisualEnvelope(
            canvasSize: CGSize(width: 1_000, height: 1_000),
            visibleBounds: CGRect(x: 700, y: 200, width: 120, height: 500)
        )
        let visualRect = OverlayGeometry.petVisualScreenRect(
            displayWidthPt: displayWidthPt,
            petScreenCenter: petCenter,
            petVisualEnvelope: envelope
        )
        let menuCenter = OverlayGeometry.menuScreenCenter(
            petScreenCenter: petCenter,
            displayWidthPt: displayWidthPt,
            petVisualEnvelope: envelope
        )
        #expect(visualRect.midX > petCenter.x)
        #expect(menuCenter.x > visualRect.maxX)
        #expect(OverlayGeometry.shouldShowControls(
            at: CGPoint(x: visualRect.midX, y: visualRect.midY),
            displayWidthPt: displayWidthPt,
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
                displayWidthPt: 112,
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
        #expect(handles(CGPoint(x: petCenter.x - 36, y: petCenter.y), hitTest: hitTest))

        // A frame mask is briefly unavailable during launch and state changes.
        // Keep the geometric pet region interactive until pixel data arrives.
        #expect(handles(petCenter, hitTest: nil))
        #expect(handles(
            OverlayGeometry.menuCenter(petCenter: petCenter, displayWidthPt: 112),
            hitTest: nil
        ))
    }

    @Test
    func pointerOwnershipPolicyHasOneExplicitPriorityOrder() {
        let interactionID = UUID()
        let base = OverlayPointerOwnershipInput(
            overlayVisible: true,
            primaryButtonDown: false,
            activeInteractionID: nil,
            maskState: .valid,
            validMaskPixelIsOpaque: false,
            pointerInBubble: false,
            pointerInMenu: false,
            pointerInGeometricPetRegion: true
        )
        #expect(OverlayPointerOwnershipPolicy.resolve(base) == .passthrough)

        var opaque = base
        opaque.validMaskPixelIsOpaque = true
        #expect(OverlayPointerOwnershipPolicy.resolve(opaque) == .pet)

        for fallback in [OverlayPointerMaskState.missing, .stale] {
            var input = base
            input.maskState = fallback
            #expect(OverlayPointerOwnershipPolicy.resolve(input) == .pet)
        }

        var auxiliary = base
        auxiliary.pointerInGeometricPetRegion = false
        auxiliary.pointerInBubble = true
        #expect(
            OverlayPointerOwnershipPolicy.resolve(auxiliary)
                == .auxiliarySurface
        )

        var active = base
        active.activeInteractionID = interactionID
        #expect(
            OverlayPointerOwnershipPolicy.resolve(active)
                == .activeLease(interactionID)
        )
        active.overlayVisible = false
        #expect(
            OverlayPointerOwnershipPolicy.resolve(active) == .passthrough
        )
    }

    @Test
    func pointerMonitorPreDispatchesExactMouseDownOwnership() throws {
        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentPetCompanion", isDirectory: true)
        let controllerSource = try String(
            contentsOf: sourceDirectory.appendingPathComponent(
                "Overlay/PetOverlayController.swift"
            ),
            encoding: .utf8
        )
        let monitorStart = try #require(controllerSource.range(
            of: "final class OverlayPointerEventMonitor"
        ))
        let monitorEnd = try #require(controllerSource.range(
            of: "private final class PassthroughOverlayHostingView",
            range: monitorStart.upperBound..<controllerSource.endIndex
        ))
        let monitorSource = controllerSource[monitorStart.lowerBound..<monitorEnd.lowerBound]
        #expect(monitorSource.contains("CGEvent.tapCreate"))
        #expect(monitorSource.contains("tap: .cgSessionEventTap"))
        #expect(monitorSource.contains("place: .headInsertEventTap"))
        #expect(monitorSource.contains("options: .listenOnly"))
        #expect(monitorSource.contains(".leftMouseDown"))
        #expect(!monitorSource.contains("Task { @MainActor"))
        #expect(!controllerSource.contains("pointerNearPetScreenRect"))
        #expect(!controllerSource.contains("guard !isKeyWindow"))
        #expect(!controllerSource.contains("behavior.mousePassthrough"))
    }

    @Test
    func fiveHundredFirstPressAndMaskTransitionSequencesNeverLoseActiveLease() {
        for index in 0 ..< 500 {
            let interactionID = UUID()
            let initialMask: OverlayPointerMaskState = switch index % 3 {
            case 0: .missing
            case 1: .stale
            default: .valid
            }
            let first = OverlayPointerOwnershipPolicy.resolve(
                OverlayPointerOwnershipInput(
                    overlayVisible: true,
                    primaryButtonDown: true,
                    activeInteractionID: nil,
                    maskState: initialMask,
                    validMaskPixelIsOpaque: initialMask == .valid,
                    pointerInBubble: false,
                    pointerInMenu: false,
                    pointerInGeometricPetRegion: true
                )
            )
            #expect(first.isOwnedByOverlay)

            let transitioned = OverlayPointerOwnershipPolicy.resolve(
                OverlayPointerOwnershipInput(
                    overlayVisible: true,
                    primaryButtonDown: true,
                    activeInteractionID: interactionID,
                    maskState: index.isMultiple(of: 2) ? .valid : .stale,
                    validMaskPixelIsOpaque: false,
                    pointerInBubble: false,
                    pointerInMenu: false,
                    pointerInGeometricPetRegion: false
                )
            )
            #expect(transitioned == .activeLease(interactionID))
        }
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

        func topLeftPointForPixel(
            x: Int,
            topRow: Int,
            displayWidthPt: CGFloat
        ) -> CGPoint {
            let drawableSize = OverlayGeometry.petVisibleSize(
                displayWidthPt: displayWidthPt
            )
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

        for displayWidthPt in [CGFloat(100), CGFloat(300)] {
            let opaqueTopLeft = topLeftPointForPixel(
                x: 0,
                topRow: 0,
                displayWidthPt: displayWidthPt
            )
            let transparentBottomLeft = topLeftPointForPixel(
                x: 0,
                topRow: 1,
                displayWidthPt: displayWidthPt
            )

            #expect(OverlayGeometry.petFrameContainsOpaquePixel(
                atTopLeftPoint: opaqueTopLeft,
                displayWidthPt: displayWidthPt,
                petCenter: petCenter,
                frameHitTest: hitTest
            ))
            #expect(!OverlayGeometry.petFrameContainsOpaquePixel(
                atTopLeftPoint: transparentBottomLeft,
                displayWidthPt: displayWidthPt,
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
    func transparentPetPixelsAlwaysPassThrough() throws {
        let transparentMask = try #require(OverlayPetAlphaMask(
            pixelWidth: 1,
            pixelHeight: 1,
            alphaValuesTopToBottom: [0]
        ))
        let containerSize = CGSize(width: 800, height: 600)
        let panelFrame = CGRect(origin: .zero, size: containerSize)

        #expect(!OverlayGeometry.shouldHandleMouse(
            atTopLeftPoint: CGPoint(x: 40, y: 40),
            in: containerSize,
            displayWidthPt: 112,
            petCenter: CGPoint(x: 400, y: 300),
            bubbleVisible: false,
            clickMenuEnabled: false,
            panelFrame: panelFrame,
            screenFrame: panelFrame,
            includeBubble: false,
            petFrameHitTest: OverlayPetFrameHitTest(
                canvasSize: CGSize(width: 1, height: 1),
                alphaMask: transparentMask
            )
        ))
    }

    @Test
    func testBubbleTracksSizedVisiblePetTopForDifferentActionEnvelopes() {
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

        func bubbleBottom(
            displayWidthPt: CGFloat,
            envelope: OverlayPetVisualEnvelope
        ) -> CGFloat {
            let center = OverlayGeometry.bubbleScreenCenter(
                bubbleSize: bubbleSize,
                displayWidthPt: displayWidthPt,
                petScreenCenter: petCenter,
                screenFrame: visibleFrame,
                petVisualEnvelope: envelope
            )
            return center.y - bubbleSize.height / 2
        }

        for displayWidthPt: CGFloat in [100, 112, 160] {
            let offsets = OverlayGeometry.petVisualVerticalOffsets(
                displayWidthPt: displayWidthPt,
                envelope: tallAction
            )
            let bubbleCenter = OverlayGeometry.bubbleScreenCenter(
                bubbleSize: bubbleSize,
                displayWidthPt: displayWidthPt,
                petScreenCenter: petCenter,
                screenFrame: visibleFrame,
                petVisualEnvelope: tallAction
            )
            let bubbleRect = OverlayGeometry.rect(center: bubbleCenter, size: bubbleSize)
            let menuRect = OverlayGeometry.rect(
                center: OverlayGeometry.menuScreenCenter(
                    petScreenCenter: petCenter,
                    displayWidthPt: displayWidthPt,
                    petVisualEnvelope: tallAction
                ),
                size: OverlayGeometry.menuHitSize
            )
            #expect(abs(
                bubbleBottom(displayWidthPt: displayWidthPt, envelope: tallAction)
                    - (petCenter.y + offsets.top + OverlayGeometry.bubbleGap)
            ) < 0.001)
            #expect(!bubbleRect.intersects(menuRect))
            #expect(bubbleRect.minY - menuRect.maxY >= OverlayGeometry.bubbleGap)
            #expect(
                bubbleBottom(displayWidthPt: displayWidthPt, envelope: tallAction)
                    > bubbleBottom(displayWidthPt: displayWidthPt, envelope: shortAction)
            )
        }

        let smallOffset = bubbleBottom(displayWidthPt: 100, envelope: tallAction)
            - petCenter.y
        let largeOffset = bubbleBottom(displayWidthPt: 300, envelope: tallAction)
            - petCenter.y
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
            displayWidthPt: 300,
            envelope: envelope
        ).top
        let bubbleCenter = OverlayGeometry.bubbleScreenCenter(
            bubbleSize: bubbleSize,
            displayWidthPt: 300,
            petScreenCenter: petCenter,
            screenFrame: visibleFrame,
            petVisualEnvelope: envelope
        )
        let bubbleRect = OverlayGeometry.rect(center: bubbleCenter, size: bubbleSize)

        #expect(abs(bubbleRect.minY - (petTop + OverlayGeometry.bubbleGap)) < 0.001)
    }

    @Test
    func bubbleWidthAndAnchorStayBoundedAcrossPetAndSessionMatrix() {
        func content(sessionCount: Int, language: String) -> OverlayBubbleContent {
            let sessions = (0 ..< sessionCount).map { index in
                OverlaySessionContent(
                    id: "\(language)-\(index)",
                    source: .codex,
                    sessionID: "session-\(index)",
                    eventType: index.isMultiple(of: 3) ? .waiting : .tool,
                    sessionTitle: language == "zh"
                        ? String(repeating: "长标题", count: 20)
                        : String(repeating: "Long session title ", count: 10),
                    messageText: language == "zh"
                        ? String(repeating: "等待用户输入并继续处理。", count: 20)
                        : String(repeating: "Waiting for bounded user input. ", count: 20),
                    statusText: "",
                    navigation: AgentSessionNavigation()
                )
            }
            return OverlayBubbleContent(
                id: "content-\(language)-\(sessionCount)",
                source: .codex,
                agentName: "Codex",
                sessions: sessions,
                isExpanded: true
            )
        }

        let ordinary = OverlayGeometry.resolvedBubbleSize(
            in: CGSize(width: 1_200, height: 800)
        )
        #expect(ordinary.width == 344)
        #expect(OverlayGeometry.resolvedBubbleSize(
            in: CGSize(width: 352, height: 800)
        ).width == 320)
        #expect(OverlayGeometry.resolvedBubbleSize(
            in: CGSize(width: 240, height: 800)
        ).width == 208)

        let visibleFrame = CGRect(x: -400, y: 24, width: 1_200, height: 760)
        let centers = [
            CGPoint(x: visibleFrame.midX, y: visibleFrame.midY),
            CGPoint(x: visibleFrame.minX + 80, y: visibleFrame.midY),
            CGPoint(x: visibleFrame.maxX - 80, y: visibleFrame.midY),
            CGPoint(x: visibleFrame.midX, y: visibleFrame.maxY - 80),
            CGPoint(x: visibleFrame.midX, y: visibleFrame.minY + 80),
        ]
        for petWidth: CGFloat in [100, 112, 300] {
            for sessionCount in [1, 2, 8] {
                for language in ["zh", "en"] {
                    for center in centers {
                        let layout = OverlayGeometry.bubblePanelLayout(
                            displayWidthPt: petWidth,
                            petScreenCenter: center,
                            visibleFrame: visibleFrame,
                            contents: [content(
                                sessionCount: sessionCount,
                                language: language
                            )],
                            previousAnchor: nil
                        )
                        // Horizontal placement is the part that adapts to an
                        // edge, so the bubble is always within the horizontal
                        // span. Vertically it keeps its authored distance from
                        // the pet, so it is fully on screen exactly when one
                        // side of the pet has room for it.
                        #expect(layout.frame.minX >= visibleFrame.minX)
                        #expect(layout.frame.maxX <= visibleFrame.maxX)
                        let offsets = OverlayGeometry.petVisualVerticalOffsets(
                            displayWidthPt: petWidth,
                            envelope: nil
                        )
                        let safeFrame = visibleFrame.insetBy(dx: 8, dy: 8)
                        let roomAbove = safeFrame.maxY
                            - (center.y + offsets.top + OverlayGeometry.bubbleGap)
                        let roomBelow = (center.y + offsets.bottom
                            - OverlayGeometry.bubbleGap) - safeFrame.minY
                        if max(roomAbove, roomBelow) >= layout.frame.height {
                            #expect(layout.frame.minY >= visibleFrame.minY)
                            #expect(layout.frame.maxY <= visibleFrame.maxY)
                        }
                        #expect(layout.frame.width >= 304)
                        #expect(layout.frame.width <= 360)
                    }
                }
            }
        }
    }

    @Test
    func previousLegalBubbleAnchorIsStableUntilItNoLongerFits() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let bubbleSize = CGSize(width: 344, height: 120)
        for direction in OverlayBubbleAnchorDirection.allCases {
            let stable = OverlayGeometry.bubblePlacement(
                bubbleSize: bubbleSize,
                displayWidthPt: 112,
                petScreenCenter: CGPoint(x: 600, y: 400),
                screenFrame: visibleFrame,
                previousAnchor: OverlayBubbleAnchor(
                    direction: direction,
                    alignsLeft: false
                )
            )
            #expect(stable.anchor.direction == direction)
        }

        // A pet pinned under the top edge has no room above it, so the bubble
        // moves to the other side of the pet rather than closing the gap.
        let moved = OverlayGeometry.bubblePlacement(
            bubbleSize: bubbleSize,
            displayWidthPt: 112,
            petScreenCenter: CGPoint(x: 600, y: 760),
            screenFrame: visibleFrame,
            previousAnchor: OverlayBubbleAnchor(
                direction: .above,
                alignsLeft: false
            )
        )
        #expect(moved.anchor.direction == .below)
        #expect(visibleFrame.contains(OverlayGeometry.rect(
            center: moved.center,
            size: bubbleSize
        )))
    }

    @Test
    func testSideControlsTrackVisiblePetRightEdgeInsteadOfTransparentCanvas() {
        let petCenter = CGPoint(x: 700, y: 420)
        let envelope = OverlayPetVisualEnvelope(
            canvasSize: CGSize(width: 384, height: 416),
            visibleBounds: CGRect(x: 54, y: 20, width: 252, height: 370)
        )

        for displayWidthPt: CGFloat in [100, 112, 300] {
            let fallbackMenu = OverlayGeometry.menuScreenCenter(
                petScreenCenter: petCenter,
                displayWidthPt: displayWidthPt
            )
            let fittedMenu = OverlayGeometry.menuScreenCenter(
                petScreenCenter: petCenter,
                displayWidthPt: displayWidthPt,
                petVisualEnvelope: envelope
            )

            #expect(fittedMenu.x < fallbackMenu.x)
        }

        let smallInset = OverlayGeometry.menuScreenCenter(
            petScreenCenter: petCenter,
            displayWidthPt: 100
        ).x - OverlayGeometry.menuScreenCenter(
            petScreenCenter: petCenter,
            displayWidthPt: 100,
            petVisualEnvelope: envelope
        ).x
        let largeInset = OverlayGeometry.menuScreenCenter(
            petScreenCenter: petCenter,
            displayWidthPt: 300
        ).x - OverlayGeometry.menuScreenCenter(
            petScreenCenter: petCenter,
            displayWidthPt: 300,
            petVisualEnvelope: envelope
        ).x
        #expect(largeInset > smallInset)
    }

    @Test
    func testPetAndControlsStayInsideEachMovementEdgeAtEverySupportedSize() {
        let displays = [
            CGRect(x: 0.001, y: 25.002, width: 1511.997, height: 919.995),
            CGRect(x: -1279.999, y: 0.003, width: 1279.998, height: 759.994)
        ]
        let displayWidths: [CGFloat] = [100, 112, 300]

        for visibleFrame in displays {
            for displayWidthPt in displayWidths {
                let proposals = [
                    CGPoint(x: visibleFrame.minX, y: visibleFrame.minY),
                    CGPoint(x: visibleFrame.maxX, y: visibleFrame.minY),
                    CGPoint(x: visibleFrame.minX, y: visibleFrame.maxY),
                    CGPoint(x: visibleFrame.maxX, y: visibleFrame.maxY)
                ]

                for proposal in proposals {
                    let center = OverlayGeometry.clampedPetScreenCenter(
                        proposal,
                        displayWidthPt: displayWidthPt,
                        visibleFrame: visibleFrame,
                        clickMenuEnabled: true
                    )
                    let bounds = OverlayGeometry.petMovementScreenBounds(
                        displayWidthPt: displayWidthPt,
                        petScreenCenter: center,
                        clickMenuEnabled: true
                    )
                    #expect(
                        visibleFrame.insetBy(dx: -0.5, dy: -0.5).contains(bounds),
                        "movement bounds \(bounds) escaped \(visibleFrame) at \(displayWidthPt) pt"
                    )
                    #expect(center.x * 256 == (center.x * 256).rounded())
                    #expect(center.y * 256 == (center.y * 256).rounded())
                }
            }
        }
    }

    @Test
    func testClampIncludesVisiblePetAndMenuHitTarget() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let center = OverlayGeometry.clampedPetScreenCenter(
            CGPoint(x: visibleFrame.maxX, y: visibleFrame.minY),
            displayWidthPt: 112,
            visibleFrame: visibleFrame,
            clickMenuEnabled: true
        )

        let completeBounds = OverlayGeometry.petMovementScreenBounds(
            displayWidthPt: 112,
            petScreenCenter: center,
            clickMenuEnabled: true
        )
        let menuBounds = OverlayGeometry.rect(
            center: OverlayGeometry.menuScreenCenter(
                petScreenCenter: center,
                displayWidthPt: 112
            ),
            size: OverlayGeometry.menuHitSize
        )

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
            displayWidthPt: 136,
            visibleFrame: movementFrame,
            clickMenuEnabled: true,
            petVisualEnvelope: envelope
        )
        let movementBounds = OverlayGeometry.petMovementScreenBounds(
            displayWidthPt: 136,
            petScreenCenter: center,
            clickMenuEnabled: true,
            petVisualEnvelope: envelope
        )
        let oldVisibleFrameCenter = OverlayGeometry.clampedPetScreenCenter(
            CGPoint(x: 900, y: -1_000),
            displayWidthPt: 136,
            visibleFrame: visibleFrame,
            clickMenuEnabled: true
        )

        #expect(movementBounds.minY >= 1)
        #expect(
            movementBounds.minY - 1
                < CGFloat(OverlayPlacementCanonicalization.quantumPt)
        )
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

            for displayWidthPt in [
                OverlayGeometry.minimumDisplayWidthPt,
                OverlayGeometry.defaultDisplayWidthPt,
                OverlayGeometry.maximumDisplayWidthPt,
            ] {
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
                        displayWidthPt: displayWidthPt,
                        visibleFrame: movementFrame,
                        clickMenuEnabled: true,
                        petVisualEnvelope: envelope
                    )
                    let bounds = OverlayGeometry.petMovementScreenBounds(
                        displayWidthPt: displayWidthPt,
                        petScreenCenter: center,
                        clickMenuEnabled: true,
                        petVisualEnvelope: envelope
                    )
                    #expect(
                        movementFrame.insetBy(dx: -0.5, dy: -0.5).contains(bounds),
                        "actual pet/control bounds \(bounds) escaped \(movementFrame) at \(displayWidthPt) pt"
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
    func displayWidthClampsToTheContract() {
        #expect(OverlayGeometry.clampedDisplayWidthPt(20)
            == OverlayGeometry.minimumDisplayWidthPt)
        #expect(OverlayGeometry.clampedDisplayWidthPt(400)
            == OverlayGeometry.maximumDisplayWidthPt)
        #expect(OverlayGeometry.clampedDisplayWidthPt(80) == 100)
        #expect(OverlayGeometry.clampedDisplayWidthPt(100) == 100)
        #expect(OverlayGeometry.clampedDisplayWidthPt(300) == 300)
        #expect(OverlayGeometry.clampedDisplayWidthPt(301) == 300)
        #expect(OverlayGeometry.clampedDisplayWidthPt(.nan)
            == OverlayGeometry.defaultDisplayWidthPt)
    }

    @Test
    func overlayControlVisibilityTracksHoverDragAndKeyboardFocus() {
        #expect(!OverlayControlVisibility.isVisible(
            pointerNearPet: false,
            petDragInProgress: false
        ))
        #expect(OverlayControlVisibility.isVisible(
            pointerNearPet: true,
            petDragInProgress: false
        ))
        #expect(OverlayControlVisibility.isVisible(
            pointerNearPet: false,
            petDragInProgress: true
        ))
        #expect(OverlayControlVisibility.isVisible(
            pointerNearPet: false,
            petDragInProgress: false,
            keyboardFocusActive: true
        ))
    }

    @Test
    func calibratedWidthOnlyAppliesToNeverPositionedPlacement() {
        #expect(
            OverlayGeometry.resolvedInitialDisplayWidthPt(
                persistedDisplayWidthPt: 80,
                hasPersistedPosition: false
            ) == 112
        )
        #expect(
            OverlayGeometry.resolvedInitialDisplayWidthPt(
                persistedDisplayWidthPt: 80,
                hasPersistedPosition: true
            ) == 100
        )
        #expect(
            OverlayGeometry.resolvedInitialDisplayWidthPt(
                persistedDisplayWidthPt: 180,
                hasPersistedPosition: true
            ) == 180
        )
    }

    @Test
    func sizeChangesKeepTheBottomCenterAnchorStable() {
        let initialCenter = CGPoint(x: 640, y: 180)
        let resizedCenter = OverlayGeometry.bottomAnchoredCenter(
            from: initialCenter,
            currentDisplayWidthPt: 112,
            proposedDisplayWidthPt: 300
        )
        let initialBottom = initialCenter.y
            - OverlayGeometry.petVisibleSize(displayWidthPt: 112).height / 2
        let resizedBottom = resizedCenter.y
            - OverlayGeometry.petVisibleSize(displayWidthPt: 300).height / 2

        #expect(resizedCenter.x == initialCenter.x)
        #expect(abs(resizedBottom - initialBottom) < 0.001)
    }

    @Test
    func petClickAndDragUseOneExclusiveThreshold() {
        #expect(!OverlayPetPointerGesture.exceedsDragThreshold(
            from: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 13.99, y: 10)
        ))
        #expect(OverlayPetPointerGesture.exceedsDragThreshold(
            from: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 14, y: 10)
        ))
    }

    @Test
    func gesturePhaseAndCompareAndFinishAreExactlyOnceAcrossFiveHundredOrders() {
        for index in 0 ..< 500 {
            let interactionID = UUID()
            var session = OverlayDragSession(
                interactionID: interactionID,
                startPointerScreen: .zero,
                startAnchorScreen: CGPoint(x: 400, y: 300),
                startDisplayID: "main"
            )
            #expect(session.phase == .pressed)
            let distance: CGFloat = switch index % 3 {
            case 0: 3.999
            case 1: 4
            default: 120
            }
            session.updatePointer(CGPoint(x: distance, y: 0))
            #expect(
                session.phase == (distance >= 4 ? .dragging : .pressed)
            )
            let staleID = UUID()
            let staleFinalized = session.compareAndFinalize(
                interactionID: staleID
            )
            #expect(!staleFinalized)
            let finalized = session.compareAndFinalize(
                interactionID: interactionID
            )
            #expect(finalized)
            #expect(session.phase == .finalized)
            let duplicateFinalized = session.compareAndFinalize(
                interactionID: interactionID
            )
            #expect(!duplicateFinalized)
            let commitCount = session.hasCrossedThreshold ? 1 : 0
            #expect(commitCount == (distance >= 4 ? 1 : 0))
        }
    }

    @Test
    func auxiliaryAttachmentPolicyIsIdempotentAndCycleSafe() {
        #expect(OverlayAuxiliaryPanelAttachmentPolicy.plan(
            currentParentMatchesTarget: true,
            hasCurrentParent: true,
            wouldCreateCycle: false
        ) == .none)
        #expect(OverlayAuxiliaryPanelAttachmentPolicy.plan(
            currentParentMatchesTarget: false,
            hasCurrentParent: false,
            wouldCreateCycle: false
        ) == .attach)
        #expect(OverlayAuxiliaryPanelAttachmentPolicy.plan(
            currentParentMatchesTarget: false,
            hasCurrentParent: true,
            wouldCreateCycle: false
        ) == .reparent)
        #expect(OverlayAuxiliaryPanelAttachmentPolicy.plan(
            currentParentMatchesTarget: false,
            hasCurrentParent: true,
            wouldCreateCycle: true
        ) == .rejectCycle)
    }

    @MainActor
    @Test
    func concreteAuxiliaryWindowReattachesAndRemainsIdempotent() {
        let target = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 120, height: 130),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let wrongParent = NSPanel(
            contentRect: CGRect(x: 300, y: 0, width: 120, height: 130),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let auxiliary = NSPanel(
            contentRect: CGRect(x: 0, y: 140, width: 304, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        wrongParent.addChildWindow(auxiliary, ordered: .above)

        OverlayAuxiliaryPanelAttachment.ensure(
            parent: target,
            auxiliary: auxiliary
        )
        #expect(auxiliary.parent === target)
        #expect(wrongParent.childWindows?.contains { $0 === auxiliary } != true)
        #expect(target.childWindows?.filter { $0 === auxiliary }.count == 1)

        OverlayAuxiliaryPanelAttachment.ensure(
            parent: target,
            auxiliary: auxiliary
        )
        #expect(auxiliary.parent === target)
        #expect(target.childWindows?.filter { $0 === auxiliary }.count == 1)

        target.removeChildWindow(auxiliary)
        #expect(auxiliary.parent == nil)
        OverlayAuxiliaryPanelAttachment.ensure(
            parent: target,
            auxiliary: auxiliary
        )
        #expect(auxiliary.parent === target)
    }

    @Test
    func petPrimaryClickRunsOnceForSingleOrDoubleClickAndNeverAfterDrag() {
        #expect(OverlayPetPointerGesture.shouldPerformPrimaryClick(
            clickCount: 1,
            didDrag: false
        ))
        #expect(!OverlayPetPointerGesture.shouldPerformPrimaryClick(
            clickCount: 2,
            didDrag: false
        ))
        #expect(!OverlayPetPointerGesture.shouldPerformPrimaryClick(
            clickCount: 3,
            didDrag: false
        ))
        #expect(!OverlayPetPointerGesture.shouldPerformPrimaryClick(
            clickCount: 1,
            didDrag: true
        ))
    }

    @Test
    func dragSessionUsesAbsolutePointerDeltaWithoutAccumulatedDrift() {
        let startPointer = CGPoint(x: 120, y: 240)
        let startAnchor = CGPoint(x: 600, y: 400)
        var session = OverlayDragSession(
            startPointerScreen: startPointer,
            startAnchorScreen: startAnchor,
            startDisplayID: "main"
        )

        for sample in 1 ... 500 {
            session.updatePointer(CGPoint(
                x: startPointer.x + CGFloat(sample) * 1.25,
                y: startPointer.y - CGFloat(sample) * 0.75
            ))
        }

        #expect(session.hasCrossedThreshold)
        #expect(session.proposedAnchorScreen == CGPoint(
            x: startAnchor.x + 625,
            y: startAnchor.y - 375
        ))
    }

    @Test
    func globalEventLocationsSurviveEveryScreenArrangement() {
        let arrangements = [
            CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            CGRect(x: 0, y: 0, width: 1_440, height: 900),
            CGRect(x: 0, y: 0, width: 3_456, height: 2_234),
        ]
        for zeroOrigin in arrangements {
            for sample in 0 ... 8 {
                let progress = CGFloat(sample) / 8
                let global = CGPoint(
                    x: zeroOrigin.width * progress,
                    y: zeroOrigin.height * progress
                )
                let screenPoint = OverlayPointerCoordinateSpace.screenPoint(
                    forGlobalEventLocation: global,
                    zeroOriginScreenFrame: zeroOrigin
                )
                #expect(screenPoint.x == global.x)
                #expect(screenPoint.y == zeroOrigin.height - global.y)
            }
        }
    }

    /// The defect this pins: the drag translates its own host window on every
    /// display tick, so a pointer sample read through that window's frame is
    /// short by however far the window moved since the sample was created. Fast
    /// drags queue several samples per frame and the error accumulates as the
    /// grab point sliding across the pet.
    @Test(arguments: [1.0, 9.0, 47.0])
    func fastDragHoldsTheGrabOffsetWhileTheHostWindowMovesEverySample(
        pointsPerSample: CGFloat
    ) {
        let zeroOrigin = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let startGlobal = CGPoint(x: 300, y: 700)
        let startPointer = OverlayPointerCoordinateSpace.screenPoint(
            forGlobalEventLocation: startGlobal,
            zeroOriginScreenFrame: zeroOrigin
        )
        // The pointer grabs the pet off-center, which is what makes a drift
        // visible to the user at all.
        let startAnchor = CGPoint(
            x: startPointer.x - 23,
            y: startPointer.y + 17
        )
        let grabOffset = CGPoint(
            x: startAnchor.x - startPointer.x,
            y: startAnchor.y - startPointer.y
        )
        var session = OverlayDragSession(
            startPointerScreen: startPointer,
            startAnchorScreen: startAnchor,
            startDisplayID: "zero-origin"
        )
        var hostWindowFrame = OverlayGeometry.rect(
            center: startAnchor,
            size: CGSize(width: 704, height: 640)
        )

        for sample in 1 ... 500 {
            let global = CGPoint(
                x: startGlobal.x + CGFloat(sample) * pointsPerSample,
                y: startGlobal.y - CGFloat(sample) * pointsPerSample * 0.5
            )
            let pointer = OverlayPointerCoordinateSpace.screenPoint(
                forGlobalEventLocation: global,
                zeroOriginScreenFrame: zeroOrigin
            )
            session.updatePointer(pointer)
            let presented = session.proposedAnchorScreen
            #expect(presented.x - pointer.x == grabOffset.x)
            #expect(presented.y - pointer.y == grabOffset.y)
            // Production moves this window to follow each presented center, so
            // the next sample is created against a frame that has already
            // shifted underneath the pointer.
            hostWindowFrame = OverlayGeometry.rect(
                center: presented,
                size: hostWindowFrame.size
            )
        }

        #expect(hostWindowFrame.midX == session.proposedAnchorScreen.x)
    }

    @Test
    func bubbleKeepsItsAttachedEdgeWhileADragCrossesTheScreenMidline() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_920, height: 1_055)
        let bubbleSize = CGSize(width: 344, height: 120)
        var anchor: OverlayBubbleAnchor?
        var previousCenterX: CGFloat?
        var largestStep: CGFloat = 0

        // Sweep a drag straight through the midline. Deciding the attached edge
        // from the midline alone would jump the bubble by its own width minus
        // the pet's the moment the pet crosses it.
        for sample in 0 ... 400 {
            let petCenter = CGPoint(
                x: 660 + CGFloat(sample) * 1.5,
                y: 520
            )
            let placement = OverlayGeometry.bubblePlacement(
                bubbleSize: bubbleSize,
                displayWidthPt: 112,
                petScreenCenter: petCenter,
                screenFrame: visibleFrame,
                previousAnchor: anchor
            )
            anchor = placement.anchor
            if let previousCenterX {
                largestStep = max(
                    largestStep,
                    abs(placement.center.x - previousCenterX)
                )
            }
            previousCenterX = placement.center.x
            #expect(visibleFrame.contains(OverlayGeometry.rect(
                center: placement.center,
                size: bubbleSize
            )))
        }

        // The bubble may only travel as far as the pet did between samples.
        #expect(largestStep <= 1.5 + 0.001)
    }

    @MainActor
    @Test
    func sustainedDeliveryKeepsTheTickSourceArmedForTheWholeGesture() throws {
        let factory = FakeOverlayDisplayTickFactory()
        let driver = OverlayDisplayLinkCoalescer<Int> { _, onTick in
            factory.makeSource(onTick: onTick)
        }
        let cadence = OverlayDisplayRefreshCadence(
            displayID: "display",
            framesPerSecond: 120
        )
        var delivered: [Int] = []

        driver.beginSustainedDelivery()
        for sample in 1 ... 4 {
            driver.submit(
                sample,
                targetDisplayID: cadence.displayID,
                screen: nil,
                fallbackCadence: cadence,
                deliver: { delivered.append($0) }
            )
            let source = try #require(factory.sources.last)
            source.fire()
            // Re-arming a paused link per sample can miss the next vsync, so
            // the source stays live until the gesture finishes.
            #expect(!source.isPaused)
        }
        #expect(delivered == [1, 2, 3, 4])

        driver.endSustainedDelivery()
        #expect(try #require(factory.sources.last).isPaused)
    }

    @Test(arguments: [
        (500, 50.0),
        (500, 60.0),
        (500, 120.0),
        (1_000, 50.0),
        (1_000, 60.0),
        (1_000, 120.0),
    ])
    func directManipulationCoalescesToTheTargetDisplayRefreshRate(
        sampleCount: Int,
        framesPerSecond: Double
    ) throws {
        let cadence = OverlayDisplayRefreshCadence(
            displayID: "test-display",
            framesPerSecond: framesPerSecond
        )
        var coalescer = OverlayDisplayRefreshCoalescer<Int>()
        var delivered: [Int] = []
        var lastDeliveryTime = 0.0

        for sample in 0 ..< sampleCount {
            let sampleTime = Double(sample) / Double(sampleCount)
            if let deadline = coalescer.scheduledDeadline,
               deadline <= sampleTime,
               let value = coalescer.takePending(deliveredAt: deadline) {
                delivered.append(value)
                lastDeliveryTime = deadline
            }
            _ = coalescer.submit(
                sample,
                at: sampleTime,
                cadence: cadence
            )
        }
        if let deadline = coalescer.scheduledDeadline,
           let value = coalescer.takePending(deliveredAt: deadline) {
            delivered.append(value)
            lastDeliveryTime = deadline
        }

        let refreshCycles = Int(ceil(
            lastDeliveryTime / cadence.intervalSeconds
        ))
        #expect(delivered.count <= refreshCycles)
        #expect(try #require(delivered.last) == sampleCount - 1)
    }

    @Test
    func directManipulationReschedulesWhenTheTargetDisplayChanges() throws {
        let slow = OverlayDisplayRefreshCadence(
            displayID: "slow",
            framesPerSecond: 50
        )
        let fast = OverlayDisplayRefreshCadence(
            displayID: "fast",
            framesPerSecond: 120
        )
        var coalescer = OverlayDisplayRefreshCoalescer<Int>()

        let slowDeadline = coalescer.submit(1, at: 0, cadence: slow)
        #expect(abs(slowDeadline - 0.02) < 0.000_001)
        let fastDeadline = coalescer.submit(2, at: 0.005, cadence: fast)
        #expect(fastDeadline < slowDeadline)
        #expect(abs(fastDeadline - (0.005 + 1.0 / 120.0)) < 0.000_001)
        #expect(coalescer.takePending(deliveredAt: fastDeadline) == 2)

        let nextSlowDeadline = coalescer.submit(
            3,
            at: fastDeadline + 0.001,
            cadence: slow
        )
        #expect(abs(nextSlowDeadline - (fastDeadline + 0.02)) < 0.000_001)
        #expect(coalescer.takePending(deliveredAt: nextSlowDeadline) == 3)
    }

    @MainActor
    @Test(arguments: [
        (500, 50),
        (500, 60),
        (500, 120),
        (1_000, 50),
        (1_000, 60),
        (1_000, 120),
    ])
    func displayLinkDriverDeliversAtMostOncePerInjectedTick(
        sampleCount: Int,
        tickCount: Int
    ) throws {
        let factory = FakeOverlayDisplayTickFactory()
        let driver = OverlayDisplayLinkCoalescer<Int> { _, onTick in
            factory.makeSource(onTick: onTick)
        }
        let cadence = OverlayDisplayRefreshCadence(
            displayID: "display",
            framesPerSecond: Double(tickCount)
        )
        var delivered: [Int] = []

        for tick in 0 ..< tickCount {
            let lower = tick * sampleCount / tickCount
            let upper = (tick + 1) * sampleCount / tickCount
            for sample in lower ..< upper {
                driver.submit(
                    sample,
                    targetDisplayID: cadence.displayID,
                    screen: nil,
                    fallbackCadence: cadence,
                    deliver: { delivered.append($0) }
                )
            }
            try #require(factory.sources.last).fire()
        }

        #expect(delivered.count <= tickCount)
        #expect(try #require(delivered.last) == sampleCount - 1)
        #expect(try #require(factory.sources.last).isPaused)
    }

    @MainActor
    @Test
    func displayLinkDriverRebindsAcrossScreensAndReleaseFlushesLatest() throws {
        let factory = FakeOverlayDisplayTickFactory()
        let driver = OverlayDisplayLinkCoalescer<Int> { _, onTick in
            factory.makeSource(onTick: onTick)
        }
        let cadence = OverlayDisplayRefreshCadence(
            displayID: "fallback",
            framesPerSecond: 60
        )
        var delivered: [Int] = []

        driver.submit(
            1,
            targetDisplayID: "left",
            screen: nil,
            fallbackCadence: cadence,
            deliver: { delivered.append($0) }
        )
        driver.submit(
            2,
            targetDisplayID: "left",
            screen: nil,
            fallbackCadence: cadence,
            deliver: { delivered.append($0) }
        )
        let left = try #require(factory.sources.first)
        #expect(factory.sources.count == 1)

        driver.submit(
            3,
            targetDisplayID: "right",
            screen: nil,
            fallbackCadence: cadence,
            deliver: { delivered.append($0) }
        )
        let right = try #require(factory.sources.last)
        #expect(factory.sources.count == 2)
        #expect(left.invalidated)
        left.fire()
        #expect(delivered.isEmpty)

        right.fire()
        #expect(delivered == [3])
        #expect(right.isPaused)

        driver.submit(
            4,
            targetDisplayID: "right",
            screen: nil,
            fallbackCadence: cadence,
            deliver: { delivered.append($0) }
        )
        driver.submit(
            5,
            targetDisplayID: "right",
            screen: nil,
            fallbackCadence: cadence,
            deliver: { delivered.append($0) }
        )
        driver.flushNow()
        #expect(delivered == [3, 5])
        #expect(right.isPaused)

        driver.submit(
            6,
            targetDisplayID: "right",
            screen: nil,
            fallbackCadence: cadence,
            deliver: { delivered.append($0) }
        )
        driver.invalidate()
        #expect(right.invalidated)
        #expect(!driver.hasPending)
        right.fire()
        #expect(delivered == [3, 5])
    }

    @MainActor
    @Test(arguments: [500, 1_000])
    func displayLinkDeliveriesMoveTheCompositionAtMostOncePerTick(
        sampleCount: Int
    ) throws {
        let tickCount = 60
        let factory = FakeOverlayDisplayTickFactory()
        let driver = OverlayDisplayLinkCoalescer<CGPoint> { _, onTick in
            factory.makeSource(onTick: onTick)
        }
        let cadence = OverlayDisplayRefreshCadence(
            displayID: "display",
            framesPerSecond: Double(tickCount)
        )
        let initialFrame = CGRect(x: 300, y: 200, width: 704, height: 640)
        let startCenter = CGPoint(x: 600, y: 400)
        var parentFrame = initialFrame
        let anchor = OverlayDirectManipulationAnchor(
            panelFrame: initialFrame,
            petScreenCenter: startCenter
        )
        var frameSetOperations: [OverlayInteractionWindowRole] = []
        var bubbleAnchor: OverlayBubbleAnchor?
        var presentedFrames: [OverlayInteractionWindowMove] = []

        for tick in 0 ..< tickCount {
            let lower = tick * sampleCount / tickCount
            let upper = (tick + 1) * sampleCount / tickCount
            for sample in lower ..< upper {
                let center = CGPoint(
                    x: startCenter.x + CGFloat(sample + 1) * 0.5,
                    y: startCenter.y + CGFloat(sample + 1) * 0.25
                )
                driver.submit(
                    center,
                    targetDisplayID: cadence.displayID,
                    screen: nil,
                    fallbackCadence: cadence
                ) { center in
                    let plan = OverlayDirectManipulationMovePlan.plan(
                        anchor: anchor,
                        parentFrame: parentFrame,
                        presentedPetCenter: center,
                        auxiliary: OverlayDirectManipulationAuxiliaryInput(
                            displayWidthPt: 112,
                            visibleFrame: CGRect(
                                x: 0,
                                y: 0,
                                width: 1_920,
                                height: 1_055
                            ),
                            petVisualEnvelope: nil,
                            bubbleSize: CGSize(width: 344, height: 120),
                            previousBubbleAnchor: bubbleAnchor,
                            menuVisible: true
                        )
                    )
                    for move in plan.moves {
                        frameSetOperations.append(move.role)
                        if move.role == .parentPetPanel {
                            parentFrame = move.frame
                        }
                    }
                    bubbleAnchor = plan.bubbleAnchor
                    presentedFrames = plan.moves
                }
            }
            try #require(factory.sources.last).fire()
        }

        let finalCenter = CGPoint(
            x: startCenter.x + CGFloat(sampleCount) * 0.5,
            y: startCenter.y + CGFloat(sampleCount) * 0.25
        )
        let expectedFrame = initialFrame.offsetBy(
            dx: finalCenter.x - startCenter.x,
            dy: finalCenter.y - startCenter.y
        )
        // Every sample still collapses to at most one presentation per tick,
        // and one presentation now carries the whole composition instead of
        // deferring the auxiliary panels to a post-release correction.
        let parentMoves = frameSetOperations.filter { $0 == .parentPetPanel }
        #expect(parentMoves.count <= tickCount)
        #expect(frameSetOperations.contains(.bubbleChildPanel))
        #expect(frameSetOperations.contains(.menuChildPanel))
        #expect(parentFrame == expectedFrame)

        // The bubble tracks the final pet center within the same delivery, so
        // no auxiliary reconciliation is left over for the release.
        let bubbleFrame = try #require(
            presentedFrames.first { $0.role == .bubbleChildPanel }?.frame
        )
        let expectedBubbleCenter = OverlayGeometry.bubblePlacement(
            bubbleSize: CGSize(width: 344, height: 120),
            displayWidthPt: 112,
            petScreenCenter: finalCenter,
            screenFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_055),
            previousAnchor: bubbleAnchor
        ).center
        #expect(hypot(
            bubbleFrame.midX - expectedBubbleCenter.x,
            bubbleFrame.midY - expectedBubbleCenter.y
        ) <= 0.001)
    }

    @Test
    func directManipulationFreezesAuxiliaryRelativeFramesForOneHundredSamples() {
        let parent = CGRect(x: 400, y: 240, width: 140, height: 160)
        let bubble = CGRect(x: 210, y: 410, width: 344, height: 120)
        let menu = CGRect(x: 548, y: 330, width: 38, height: 38)
        let frozen = OverlayAuxiliaryRelativeFrameSnapshot.capture(
            parentFrame: parent,
            bubbleFrame: bubble,
            menuFrame: menu
        )
        for sample in 0 ..< 100 {
            let movedParent = parent.offsetBy(
                dx: CGFloat(sample) * 3.25,
                dy: CGFloat(sample) * -1.75
            )
            let movedBubble = bubble.offsetBy(
                dx: movedParent.minX - parent.minX,
                dy: movedParent.minY - parent.minY
            )
            let movedMenu = menu.offsetBy(
                dx: movedParent.minX - parent.minX,
                dy: movedParent.minY - parent.minY
            )
            let current = OverlayAuxiliaryRelativeFrameSnapshot.capture(
                parentFrame: movedParent,
                bubbleFrame: movedBubble,
                menuFrame: movedMenu
            )
            #expect(current == frozen)
        }
    }

    @Test
    func crossDisplayDragPreservesTheAbsoluteStartAnchorWithinOnePoint() throws {
        let left = OverlayDragDisplay(
            id: "left",
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 875)
        )
        let right = OverlayDragDisplay(
            id: "right",
            frame: CGRect(x: 1_440, y: -120, width: 1_920, height: 1_080),
            visibleFrame: CGRect(x: 1_440, y: -120, width: 1_920, height: 1_055)
        )
        let startPointer = CGPoint(x: 1_400, y: 400)
        let startAnchor = CGPoint(x: 1_360, y: 360)
        var session = OverlayDragSession(
            startPointerScreen: startPointer,
            startAnchorScreen: startAnchor,
            startDisplayID: left.id
        )

        for sample in 1 ... 1_000 {
            let progress = CGFloat(sample) / 1_000
            session.updatePointer(CGPoint(
                x: startPointer.x + 600 * progress,
                y: startPointer.y + 180 * progress
            ))
        }

        let expected = CGPoint(
            x: startAnchor.x + 600,
            y: startAnchor.y + 180
        )
        let display = try #require(OverlayDragScreenResolver.resolve(
            pointer: session.latestPointerScreen,
            proposedPetCenter: session.proposedAnchorScreen,
            displays: [left, right],
            fallbackDisplayID: session.startDisplayID
        ))
        let movementFrame = OverlayGeometry.petMovementFrame(
            screenFrame: display.frame,
            visibleFrame: display.visibleFrame
        )
        let presented = OverlayPetDragGeometry.clampedCenter(
            session.proposedAnchorScreen,
            displayWidthPt: 112,
            visibleFrame: movementFrame
        )

        #expect(display.id == right.id)
        #expect(hypot(
            session.proposedAnchorScreen.x - expected.x,
            session.proposedAnchorScreen.y - expected.y
        ) <= 1)
        #expect(hypot(presented.x - expected.x, presented.y - expected.y) <= 1)
    }

    @Test
    func petDragUsesOnlyTheHardBoundaryWithNoOvershootOrProjection() {
        let movementFrame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let displayWidthPt: CGFloat = 112
        let inside = CGPoint(x: 600, y: 400)
        #expect(OverlayPetDragGeometry.clampedCenter(
            inside,
            displayWidthPt: displayWidthPt,
            visibleFrame: movementFrame
        ) == inside)

        let proposed = CGPoint(x: -600, y: 1_200)
        let hard = OverlayGeometry.clampedPetScreenCenter(
            proposed,
            displayWidthPt: displayWidthPt,
            visibleFrame: movementFrame
        )
        let presentation = OverlayPetDragGeometry.clampedCenter(
            proposed,
            displayWidthPt: displayWidthPt,
            visibleFrame: movementFrame
        )

        #expect(presentation == hard)
        #expect(OverlayPetDragGeometry.clampedCenter(
            presentation,
            displayWidthPt: displayWidthPt,
            visibleFrame: movementFrame
        ) == presentation)
    }

    @MainActor
    @Test
    func petDragViewAccessibilityPressUsesThePrimaryClickAction() {
        let view = WindowDragRegion.DragView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        var primaryClickCount = 0
        view.onPrimaryClick = { primaryClickCount += 1 }

        #expect(view.accessibilityRole() == .button)
        #expect(view.accessibilityPerformPress())
        #expect(primaryClickCount == 1)
    }

    @Test
    func expiredCanonicalStateCannotDrivePetWithoutAProjectedSession() throws {
        let ghost = try JSONDecoder().decode(
            ActiveAgentState.self,
            from: Data(
                #"{"state":"tool","official_status":"running","source":"codex","session_id":"ghost-session","session_active":true,"source_session_sequence":2,"priority":300,"event":{"id":"ghost-tool","source":"codex","session_id":"ghost-session","event_type":"tool","title":"执行工具","created_at":"2026-07-29T00:00:00Z"}}"#.utf8
            )
        )

        #expect(OverlayPresentedAgentState.resolve(
            canonicalState: ghost,
            activeSessions: [],
            dismissedSessionIDs: []
        ) == nil)
        #expect(OverlayPresentedAgentState.resolve(
            canonicalState: ghost,
            activeSessions: [ghost],
            dismissedSessionIDs: []
        )?.event.id == "ghost-tool")
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
            keyboardFocusActive: true
        ))
        #expect((0.12 ... 0.16).contains(OverlayMotion.controlFadeDuration))
        #expect(OverlayMotion.controlFadeDelay == .milliseconds(140))
        #expect((0.14 ... 0.18).contains(OverlayMotion.bubbleLayoutDuration))
        #expect(OverlayMotion.bubbleLayoutDelay == .milliseconds(160))
        #expect(OverlayMotion.reducedMotionCrossfadeDuration > 0)
        #expect(OverlayMotion.reducedMotionCrossfadeDuration <= 0.22)
    }

    @Test
    func overlayContentPrefersAuthoritativeDisplayFieldsOverEmbeddedEventCopies() throws {
        let displayTitle = "修复宠物消息气泡"
        let displayReply = "气泡已经恢复显示最新回复。"
        let displayActivity = "正在运行已校验的构建工具"
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
            "event_type":"done",
            "title":"已完成",
            "detail":null,
            "payload_json":{"message_role":"assistant","message_content":"\(rawPrompt)"},
            "created_at":"2026-07-21T00:00:00Z"
          },
          "session_title":"\(displayTitle)",
          "session_user_message":{"role":"user","content":"\(displayTitle)"},
          "session_message":{"role":"assistant","content":"\(displayReply)"},
          "session_activity":{"kind":"command","content":"\(displayActivity)"},
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
        #expect(content.activityText == displayActivity)
        #expect(content.messageText == displayReply)
        #expect(content.primaryDetailText == displayReply)
        #expect(content.secondaryDetailText == displayActivity)
        #expect(content.detailText == [displayReply, displayActivity].joined(separator: "\n"))
        #expect(content.detailText.contains(displayActivity))
        #expect(content.detailText.contains(displayReply))
        #expect(content.navigation.sessionOpen == true)
        #expect(!content.sessionTitle.contains(rawPrompt))
        #expect(!content.detailText.contains(rawPrompt))
        #expect(!content.detailText.contains(rawCommand))
    }

    @Test
    func overlayDoesNotInventToolActivityWhenNoDetailExists() throws {
        let state = try JSONDecoder().decode(
            ActiveAgentState.self,
            from: Data(
                #"{"state":"tool","official_status":"running","source":"codex","session_id":"tool-session","session_active":true,"source_session_sequence":2,"priority":300,"event":{"id":"tool-event","source":"codex","session_id":"tool-session","event_type":"tool","title":"执行工具","detail":null,"payload_json":{"tool_name":"Bash","activity_kind":"command","activity_content":"{\"command\":\"RAW_DO_NOT_RENDER\"}"},"created_at":"2026-07-29T00:00:00Z"},"session_title":"构建 App","session_message":{"role":"assistant","content":"正在检查构建结果。"},"session_activity":{"kind":"command","content":null},"overlay_display":{"summary_kind":"command","navigation":{"capability":"unavailable"}}}"#.utf8
            )
        )
        let content = OverlaySessionContent(state: state)

        #expect(content.activityText.isEmpty)
        #expect(content.messageText == "正在检查构建结果。")
        #expect(content.primaryDetailText == "正在检查构建结果。")
        #expect(content.secondaryDetailText == nil)
        #expect(!content.detailText.contains("{"))
        #expect(!content.detailText.contains("RAW_DO_NOT_RENDER"))
        #expect(content.statusText == APCLocalizedPresentation.overlayEventTitle(.command))
    }

    @Test
    func rawEventActivityIsNeverPromotedIntoDisplayContent() throws {
        let state = try JSONDecoder().decode(
            ActiveAgentState.self,
            from: Data(#"{"state":"done","official_status":"ready","source":"pi","session_id":"completed","session_active":false,"source_session_sequence":1,"priority":400,"lease_seconds":30,"expires_at":null,"event":{"id":"completed-event","source":"pi","session_id":"completed","event_type":"done","title":"已完成","detail":null,"payload_json":{"message_role":"assistant","message_content":"PRIVATE_RESULT_DO_NOT_RENDER","activity_kind":"plan","activity_content":"原始活动详情现在可以显示"},"created_at":"2026-07-21T00:00:00Z"}}"#.utf8)
        )
        let content = OverlaySessionContent(state: state)

        #expect(content.activityText.isEmpty)
        #expect(content.messageText.isEmpty)
        #expect(content.secondaryDetailText == nil)
        #expect(content.sessionTitle == APCLocalization.format(.overlaySessionTitleFormat, "Pi"))
        #expect(content.accessibilityReadingOrder.contains(
            APCLocalization.text(.overlayDetailCompleted)
        ))
        #expect(!content.sessionTitle.contains("PRIVATE"))
        #expect(!content.detailText.contains("PRIVATE"))
        #expect(!content.accessibilityLabel.contains("PRIVATE"))
        #expect(!content.detailText.contains("原始活动详情"))
        #expect(!content.accessibilityLabel.contains("原始活动详情"))
    }

    @Test
    func voiceOverUsesSafeLocalizedFallbackWhenProjectedCopyIsAbsent() {
        let fixtures: [(AgentEventKind, APCLocalizationKey)] = [
            (.waiting, .overlayDetailNeedsInput),
            (.done, .overlayDetailCompleted),
            (.failed, .overlayDetailBlocked),
        ]

        for (eventType, detailKey) in fixtures {
            let session = OverlaySessionContent(
                id: "fallback-\(eventType.rawValue)",
                source: .codex,
                sessionID: "fallback-\(eventType.rawValue)",
                eventType: eventType,
                sessionTitle: "Codex session",
                messageText: "",
                statusText: APCLocalizedPresentation.eventTitle(eventType),
                navigation: AgentSessionNavigation(capability: .unavailable)
            )

            #expect(session.primaryDetailText.isEmpty)
            #expect(session.secondaryDetailText == nil)
            #expect(session.accessibilityReadingOrder == [
                "Codex",
                "Codex session",
                APCLocalizedPresentation.eventTitle(eventType),
                APCLocalization.text(detailKey),
                APCLocalizedPresentation.navigationUnavailableTitle(),
            ])
        }
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
            eventType: .done,
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

        #expect(english.sessionActionLabels == ["Open ChatGPT", "Open ChatGPT"])
        #expect(english.sessionCloseActionLabels == ["Hide This Session", "Hide This Session"])
        #expect(english.closeActionLabel == "Close session bubble")
        #expect(english.groupActionLabel == "Collapse 2 sessions")
        #expect(chinese.sessionActionLabels == ["打开 ChatGPT", "打开 ChatGPT"])
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
                activity: "Return to the agent to approve, answer, or decide.",
                message: "The Agent reply remains visible."
            ),
            (
                session: "一个用于确认较长中文内容仍保持语义顺序的会话标题",
                status: "等你处理",
                activity: "请回到 Agent 完成确认、回答或决策。",
                message: "Agent 回复仍然可见。"
            ),
        ]

        for fixture in fixtures {
            let session = OverlaySessionContent(
                id: "voiceover-order",
                source: .codex,
                sessionID: "voiceover-order",
                eventType: .waiting,
                sessionTitle: fixture.session,
                activityText: fixture.activity,
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
                session.surfaceLabel,
                fixture.session,
                fixture.status,
                fixture.message,
                fixture.activity,
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

        presentation.setActive(.menu, true)
        #expect(presentation.isVisible)
        presentation.setActive(.menu, false)
        #expect(presentation.isVisible)

        presentation.setFocused(.bubble, true)
        #expect(presentation.keyboardNavigationActive)
        #expect(presentation.isVisible)
        presentation.setFocused(.bubble, false)
        #expect(!presentation.keyboardNavigationActive)
    }

    @MainActor
    @Test
    func localPetInteractionsRespectReducedMotionPressAndDragPriority() {
        let presentation = OverlayInteractionPresentationState()
        let interactionID = UUID()

        presentation.beginPressFeedback(enabled: false, reduceMotion: false)
        #expect(!presentation.pressFeedbackActive)
        presentation.beginPressFeedback(enabled: true, reduceMotion: true)
        #expect(!presentation.pressFeedbackActive)
        presentation.beginPressFeedback(enabled: true, reduceMotion: false)
        #expect(presentation.pressFeedbackActive)

        presentation.beginDrag(interactionID: interactionID, center: .zero)
        presentation.updateDrag(
            interactionID: interactionID,
            center: CGPoint(x: -8, y: 0)
        )
        #expect(!presentation.pressFeedbackActive)
        #expect(presentation.petInteraction?.stateName == "drag_left")

        presentation.updateDrag(
            interactionID: interactionID,
            center: CGPoint(x: 8, y: 0)
        )
        #expect(presentation.petInteraction?.stateName == "drag_right")
        presentation.endDrag(interactionID: interactionID)
        #expect(presentation.petInteraction == nil)

        presentation.acknowledge(reduceMotion: true)
        #expect(presentation.petInteraction == nil)
        presentation.acknowledge(reduceMotion: false)
        #expect(presentation.petInteraction?.stateName == "acknowledge")
    }

}

@MainActor
private final class FakeOverlayDisplayTickFactory {
    private(set) var sources: [FakeOverlayDisplayTickSource] = []

    func makeSource(
        onTick: @escaping @MainActor () -> Void
    ) -> FakeOverlayDisplayTickSource {
        let source = FakeOverlayDisplayTickSource(onTick: onTick)
        sources.append(source)
        return source
    }
}

@MainActor
private final class FakeOverlayDisplayTickSource: OverlayDisplayRefreshTickSource {
    var isPaused = true
    private(set) var invalidated = false
    private let onTick: @MainActor () -> Void

    init(onTick: @escaping @MainActor () -> Void) {
        self.onTick = onTick
    }

    func fire() {
        guard !invalidated, !isPaused else { return }
        onTick()
    }

    func invalidate() {
        invalidated = true
        isPaused = true
    }
}
