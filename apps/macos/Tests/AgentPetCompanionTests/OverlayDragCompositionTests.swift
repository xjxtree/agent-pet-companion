import AgentPetCompanionCore
import AppKit
import Testing
@testable import AgentPetCompanion

/// Replays a pointer path through the same composition math the live drag uses,
/// so the pet, its panel, and the attached bubble can be checked against each
/// other without a window server.
@Suite
struct OverlayDragCompositionTests {
    private struct Composition {
        let anchor: OverlayDirectManipulationAnchor
        var parentFrame: CGRect
        var bubbleFrame: CGRect
        var bubbleAnchor: OverlayBubbleAnchor?
        var presentedCenter: CGPoint
        /// The pet is drawn at a fixed point inside its panel, so its visible
        /// center follows the panel origin rather than the presented center.
        let petLocalOffset: CGVector

        var petVisualCenter: CGPoint {
            CGPoint(
                x: parentFrame.minX + petLocalOffset.dx,
                y: parentFrame.minY + petLocalOffset.dy
            )
        }
    }

    private let displayWidthPt: CGFloat = 150
    private let screenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let visibleFrame = CGRect(x: 0, y: 76, width: 1728, height: 1004)
    private let bubbleSize = CGSize(width: 344, height: 96)

    private func makeComposition(at center: CGPoint) -> Composition {
        let parentFrame = OverlayGeometry.petPanelScreenFrame(
            displayWidthPt: displayWidthPt,
            petScreenCenter: center,
            clickMenuEnabled: false
        )
        let placement = OverlayGeometry.bubblePlacement(
            bubbleSize: bubbleSize,
            displayWidthPt: displayWidthPt,
            petScreenCenter: center,
            screenFrame: visibleFrame,
            petVisualEnvelope: nil,
            previousAnchor: nil
        )
        return Composition(
            anchor: OverlayDirectManipulationAnchor(
                panelFrame: parentFrame,
                petScreenCenter: center
            ),
            parentFrame: parentFrame,
            bubbleFrame: OverlayGeometry.rect(
                center: placement.center,
                size: bubbleSize
            ),
            bubbleAnchor: placement.anchor,
            presentedCenter: center,
            petLocalOffset: CGVector(
                dx: center.x - parentFrame.minX,
                dy: center.y - parentFrame.minY
            )
        )
    }

    /// One presented drag frame, mirroring `PetOverlayController.presentPetDrag`.
    private func advance(
        _ composition: inout Composition,
        pointer: CGPoint,
        startPointer: CGPoint,
        startAnchor: CGPoint
    ) {
        let proposed = CGPoint(
            x: startAnchor.x + pointer.x - startPointer.x,
            y: startAnchor.y + pointer.y - startPointer.y
        )
        let presented = OverlayPetDragGeometry.clampedCenter(
            proposed,
            displayWidthPt: displayWidthPt,
            visibleFrame: OverlayGeometry.petMovementFrame(
                screenFrame: screenFrame,
                visibleFrame: visibleFrame
            ),
            clickMenuEnabled: false,
            petVisualEnvelope: nil
        )
        let plan = OverlayDirectManipulationMovePlan.plan(
            anchor: composition.anchor,
            parentFrame: composition.parentFrame,
            presentedPetCenter: presented,
            auxiliary: OverlayDirectManipulationAuxiliaryInput(
                displayWidthPt: displayWidthPt,
                visibleFrame: visibleFrame,
                petVisualEnvelope: nil,
                bubbleSize: bubbleSize,
                previousBubbleAnchor: composition.bubbleAnchor,
                menuVisible: false
            )
        )
        for move in plan.moves {
            switch move.role {
            case .parentPetPanel:
                // AppKit child windows ride along with the parent translation.
                let delta = CGVector(
                    dx: move.frame.minX - composition.parentFrame.minX,
                    dy: move.frame.minY - composition.parentFrame.minY
                )
                composition.parentFrame = move.frame
                composition.bubbleFrame = composition.bubbleFrame.offsetBy(
                    dx: delta.dx,
                    dy: delta.dy
                )
            case .bubbleChildPanel:
                composition.bubbleFrame = move.frame
            case .menuChildPanel:
                break
            }
        }
        if let anchor = plan.bubbleAnchor {
            composition.bubbleAnchor = anchor
        }
        composition.presentedCenter = presented
    }

    @Test
    func draggingKeepsTheBubbleLockedToThePetItIsAttachedTo() {
        let startCenter = CGPoint(x: 864, y: 620)
        var composition = makeComposition(at: startCenter)
        let startPointer = CGPoint(x: 864, y: 620)
        let initialGap = CGVector(
            dx: composition.bubbleFrame.midX - composition.petVisualCenter.x,
            dy: composition.bubbleFrame.midY - composition.petVisualCenter.y
        )

        var maximumGapDrift: CGFloat = 0
        var maximumPointerDrift: CGFloat = 0
        for step in 1...240 {
            let pointer = CGPoint(
                x: startPointer.x + CGFloat(step) * 1.7,
                y: startPointer.y - CGFloat(step) * 0.9
            )
            advance(
                &composition,
                pointer: pointer,
                startPointer: startPointer,
                startAnchor: startCenter
            )
            let gap = CGVector(
                dx: composition.bubbleFrame.midX - composition.petVisualCenter.x,
                dy: composition.bubbleFrame.midY - composition.petVisualCenter.y
            )
            maximumGapDrift = max(
                maximumGapDrift,
                hypot(gap.dx - initialGap.dx, gap.dy - initialGap.dy)
            )
            // The pointer must stay on the same point of the pet body it grabbed.
            let expectedPetCenter = CGPoint(
                x: startCenter.x + pointer.x - startPointer.x,
                y: startCenter.y + pointer.y - startPointer.y
            )
            maximumPointerDrift = max(
                maximumPointerDrift,
                hypot(
                    composition.petVisualCenter.x - expectedPetCenter.x,
                    composition.petVisualCenter.y - expectedPetCenter.y
                )
            )
        }

        #expect(maximumGapDrift < 0.5, "bubble drifted \(maximumGapDrift) pt from the pet")
        #expect(
            maximumPointerDrift < 0.5,
            "pet drifted \(maximumPointerDrift) pt from the grab point"
        )
    }

    @Test
    func bubbleStaysAboveOrBelowThePetAcrossTheWholeScreen() {
        for x in stride(from: 40.0, through: 1690.0, by: 55.0) {
            for y in stride(from: 40.0, through: 1080.0, by: 65.0) {
                let center = CGPoint(x: x, y: y)
                let placement = OverlayGeometry.bubblePlacement(
                    bubbleSize: bubbleSize,
                    displayWidthPt: displayWidthPt,
                    petScreenCenter: center,
                    screenFrame: visibleFrame,
                    petVisualEnvelope: nil,
                    previousAnchor: nil
                )
                #expect(
                    placement.anchor.direction == .above
                        || placement.anchor.direction == .below,
                    "bubble was placed \(placement.anchor.direction) of the pet at \(center)"
                )
            }
        }
    }

    @Test
    func verticalGapBetweenPetAndBubbleNeverChanges() {
        var gaps: Set<String> = []
        for x in stride(from: 40.0, through: 1690.0, by: 55.0) {
            for y in stride(from: 40.0, through: 1080.0, by: 65.0) {
                let center = CGPoint(x: x, y: y)
                let placement = OverlayGeometry.bubblePlacement(
                    bubbleSize: bubbleSize,
                    displayWidthPt: displayWidthPt,
                    petScreenCenter: center,
                    screenFrame: visibleFrame,
                    petVisualEnvelope: nil,
                    previousAnchor: nil
                )
                let offsets = OverlayGeometry.petVisualVerticalOffsets(
                    displayWidthPt: displayWidthPt,
                    envelope: nil
                )
                let gap: CGFloat = placement.anchor.direction == .above
                    ? placement.center.y - bubbleSize.height / 2
                        - (center.y + offsets.top)
                    : (center.y + offsets.bottom)
                        - (placement.center.y + bubbleSize.height / 2)
                gaps.insert(String(format: "%.2f", gap))
            }
        }
        #expect(gaps.count == 1, "vertical gap varied across the screen: \(gaps.sorted())")
    }
}
