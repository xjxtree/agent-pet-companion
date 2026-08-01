import AppKit
import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite("Overlay display width")
struct OverlayDisplayWidthTests {
    @Test
    func placementRoundTripsDisplayWidthAndRejectsTheRemovedScaleField() throws {
        let placement = OverlayPlacement(
            x: 984,
            y: 572,
            displayWidthPt: 112,
            displayId: "main"
        )
        let encoded = try JSONEncoder().encode(placement)
        let decoded = try JSONDecoder().decode(
            OverlayPlacement.self,
            from: encoded
        )

        #expect(decoded == placement)
        #expect(decoded.displayWidthPt == 112)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                OverlayPlacement.self,
                from: Data(
                    #"{"x":984,"y":572,"scale":0.72,"display_id":"main"}"#.utf8
                )
            )
        }
    }

    @Test
    func persistedPlacementRejectsNonfiniteOutOfRangeAndAnonymousValues() {
        let invalidPayloads = [
            #"{"x":0,"y":0,"display_width_pt":79,"display_id":"main"}"#,
            #"{"x":0,"y":0,"display_width_pt":225,"display_id":"main"}"#,
            #"{"x":0,"y":0,"display_width_pt":112,"display_id":""}"#,
            #"{"x":0,"y":0,"display_width_pt":112,"display_id":"  \n"}"#,
        ]
        for payload in invalidPayloads {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(
                    OverlayPlacement.self,
                    from: Data(payload.utf8)
                )
            }
        }

        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        for coordinate in ["Infinity", "-Infinity", "NaN"] {
            let payload =
                "{\"x\":\"\(coordinate)\",\"y\":0,"
                    + "\"display_width_pt\":112,\"display_id\":\"main\"}"
            #expect(throws: DecodingError.self) {
                try decoder.decode(
                    OverlayPlacement.self,
                    from: Data(payload.utf8)
                )
            }
        }
    }

    @Test(arguments: [
        (-100.0, 80.0),
        (80.0, 80.0),
        (112.0, 112.0),
        (224.0, 224.0),
        (999.0, 224.0),
    ])
    func placementClampsDisplayWidthToTheSupportedRange(
        proposed: Double,
        expected: Double
    ) {
        let placement = OverlayPlacement(displayWidthPt: proposed)
        #expect(placement.displayWidthPt == expected)
    }

    @Test
    func everySupportedAndSeededIntermediateWidthKeepsTheTwelveByThirteenCanvas() {
        var widths: [CGFloat] = [80, 112, 224]
        var seed: UInt64 = 0xA6E1_5EED
        for _ in 0 ..< 64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            widths.append(80 + CGFloat(seed % 145))
        }

        for width in widths {
            let size = OverlayGeometry.petVisibleSize(displayWidthPt: width)
            #expect(size.width == width)
            #expect(abs(size.width / size.height - 12.0 / 13.0) < 0.000_001)
        }
    }

    @Test
    func resizingAtEveryScreenEdgeAppliesOnlyTheMinimumRequiredTranslation() {
        let movementFrame = CGRect(x: 100, y: -80, width: 1_440, height: 900)

        func allowedCenters(for width: CGFloat) -> CGRect {
            let minimum = OverlayPetDragGeometry.clampedCenter(
                CGPoint(x: -1_000_000, y: -1_000_000),
                displayWidthPt: width,
                visibleFrame: movementFrame,
                clickMenuEnabled: false
            )
            let maximum = OverlayPetDragGeometry.clampedCenter(
                CGPoint(x: 1_000_000, y: 1_000_000),
                displayWidthPt: width,
                visibleFrame: movementFrame,
                clickMenuEnabled: false
            )
            return CGRect(
                x: minimum.x,
                y: minimum.y,
                width: maximum.x - minimum.x,
                height: maximum.y - minimum.y
            )
        }

        for (currentWidth, proposedWidth): (CGFloat, CGFloat) in [
            (112, 224),
            (224, 80),
        ] {
            let currentBounds = allowedCenters(for: currentWidth)
            let proposedBounds = allowedCenters(for: proposedWidth)
            let edgeCenters = [
                CGPoint(x: currentBounds.minX, y: currentBounds.midY),
                CGPoint(x: currentBounds.maxX, y: currentBounds.midY),
                CGPoint(x: currentBounds.midX, y: currentBounds.minY),
                CGPoint(x: currentBounds.midX, y: currentBounds.maxY),
            ]

            for edgeCenter in edgeCenters {
                let bottomAnchored = OverlayGeometry.bottomAnchoredCenter(
                    from: edgeCenter,
                    currentDisplayWidthPt: currentWidth,
                    proposedDisplayWidthPt: proposedWidth
                )
                let presented = OverlayPetDragGeometry.clampedCenter(
                    bottomAnchored,
                    displayWidthPt: proposedWidth,
                    visibleFrame: movementFrame,
                    clickMenuEnabled: false
                )
                let minimumTranslation = CGPoint(
                    x: min(
                        proposedBounds.maxX,
                        max(proposedBounds.minX, bottomAnchored.x)
                    ),
                    y: min(
                        proposedBounds.maxY,
                        max(proposedBounds.minY, bottomAnchored.y)
                    )
                )

                #expect(hypot(
                    presented.x - minimumTranslation.x,
                    presented.y - minimumTranslation.y
                ) < 0.001)
            }
        }
    }

    @MainActor
    @Test
    func tenSecondRapidWidthInputPreservesAnimationPositionAndPersistsOnce() async throws {
        let screen = try #require(NSScreen.main)
        let displayID = (
            screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        )?.stringValue ?? "main"
        let initialCenter = CGPoint(
            x: screen.visibleFrame.midX,
            y: screen.visibleFrame.midY
        )
        var savedWidths: [Double] = []
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, params, _ in
                guard method == "overlay.placement.update" else {
                    throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
                }
                let object = try #require(params as? [String: Any])
                savedWidths.append(try #require(object["display_width_pt"] as? Double))
                return try placementUpdateSuccess(
                    params,
                    placementRevision: UInt64(100 + savedWidths.count)
                )
            }
        )
        let activeState = makeActiveToolState()
        try store.applyStateSnapshot([
            "revision": "100",
            "overlay_placement_revision": "100",
            "behavior": try jsonObject(BehaviorSettings()),
            "behavior_revision": "1",
            "overlay_placement": try jsonObject(OverlayPlacement(
                x: initialCenter.x,
                y: initialCenter.y,
                displayWidthPt: 112,
                displayId: displayID
            )),
            "pets": [],
            "active_agent_sessions": try jsonArray([activeState]),
            "active_agent_sessions_omitted_count": 0,
            "overlay_visibility": try jsonObject(OverlayVisibility()),
            "events": [],
            "recent_events": [],
            "connections": [],
        ])
        let stateBefore = try #require(store.presentedActiveAgentState)
        let stateEntryID = OverlayPetAnimationIdentity.stateEntryID(for: stateBefore)

        let samplesPerSecond = 60
        for sample in 0 ..< 10 * samplesPerSecond {
            let width = 80 + CGFloat(sample % 145)
            store.previewOverlayDisplayWidthPt(width)
        }

        // Preview samples stay in the display-link presentation owner; they
        // neither publish persistent placement nor replace semantic state.
        #expect(savedWidths.isEmpty)
        #expect(store.overlayDisplayWidthPt == 112)
        #expect(store.overlayPetScreenCenter == initialCenter)
        #expect(OverlayPetAnimationIdentity.stateEntryID(
            for: store.presentedActiveAgentState
        ) == stateEntryID)
        #expect(store.presentedActiveAgentState?.event.id == stateBefore.event.id)

        store.commitOverlayDisplayWidthPt(180)
        for _ in 0 ..< 100 where savedWidths.count < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }

        let resizedCenter = OverlayGeometry.bottomAnchoredCenter(
            from: initialCenter,
            currentDisplayWidthPt: 112,
            proposedDisplayWidthPt: 180
        )
        #expect(savedWidths == [180])
        #expect(store.overlayDisplayWidthPt == 180)
        #expect(hypot(
            store.overlayPetScreenCenter.x - resizedCenter.x,
            store.overlayPetScreenCenter.y - resizedCenter.y
        ) < 0.5)
        #expect(OverlayPetAnimationIdentity.stateEntryID(
            for: store.presentedActiveAgentState
        ) == stateEntryID)
        #expect(store.presentedActiveAgentState?.event.id == stateBefore.event.id)

        store.resetOverlayDisplayWidthPt()
        for _ in 0 ..< 100 where savedWidths.count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(savedWidths == [180, 112])
        #expect(store.overlayDisplayWidthPt == 112)
        #expect(hypot(
            store.overlayPetScreenCenter.x - initialCenter.x,
            store.overlayPetScreenCenter.y - initialCenter.y
        ) < 0.5)
        #expect(OverlayPetAnimationIdentity.stateEntryID(
            for: store.presentedActiveAgentState
        ) == stateEntryID)
    }

    @MainActor
    @Test
    func rapidKeyboardStyleAdjustmentsPersistOnlyAfterTheDebounceWindow() async throws {
        let screen = try #require(NSScreen.main)
        let displayID = (
            screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        )?.stringValue ?? "main"
        let initialCenter = CGPoint(
            x: screen.visibleFrame.midX,
            y: screen.visibleFrame.midY
        )
        var savedWidths: [Double] = []
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, params, _ in
                guard method == "overlay.placement.update" else {
                    throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
                }
                let object = try #require(params as? [String: Any])
                savedWidths.append(try #require(object["display_width_pt"] as? Double))
                return try placementUpdateSuccess(
                    params,
                    placementRevision: 201
                )
            }
        )
        try store.applyStateSnapshot([
            "revision": "200",
            "overlay_placement_revision": "200",
            "behavior": try jsonObject(BehaviorSettings()),
            "behavior_revision": "1",
            "overlay_placement": try jsonObject(OverlayPlacement(
                x: initialCenter.x,
                y: initialCenter.y,
                displayWidthPt: 112,
                displayId: displayID
            )),
            "pets": [],
            "events": [],
            "connections": [],
        ])

        for width in 113 ... 152 {
            store.previewOverlayDisplayWidthPt(CGFloat(width))
        }
        #expect(savedWidths.isEmpty)

        try await Task.sleep(for: .milliseconds(175))
        for _ in 0 ..< 100 where savedWidths.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(savedWidths == [152])
        #expect(store.overlayDisplayWidthPt == 152)
    }

    @MainActor
    @Test
    func overlayPetAccessibilityExposesNoResizeControlOrAction() {
        let view = WindowDragRegion.DragView(
            frame: CGRect(x: 0, y: 0, width: 112, height: 122)
        )

        #expect(view.accessibilityRole() == .button)
        #expect(!view.isAccessibilitySelectorAllowed(
            NSSelectorFromString("accessibilityPerformIncrement")
        ))
        #expect(!view.isAccessibilitySelectorAllowed(
            NSSelectorFromString("accessibilityPerformDecrement")
        ))
        view.clickMenuEnabled = false
        #expect(view.accessibilityCustomActions()?.isEmpty != false)
    }

    @MainActor
    private func testBootstrapHooks() -> AppStoreBootstrapHooks {
        AppStoreBootstrapHooks(
            ensureRunning: { .alreadyHealthy },
            recover: { .alreadyHealthy },
            refreshSnapshot: { _ in },
            onReady: { _ in }
        )
    }

    private func makeActiveToolState() -> ActiveAgentState {
        let timestamp = "2026-07-31T10:00:00Z"
        return ActiveAgentState(
            state: AgentEventKind.tool.rawValue,
            officialStatus: "running",
            source: .codex,
            sessionID: "width-session",
            sessionActive: true,
            sourceSessionSequence: 1,
            priority: 300,
            leaseSeconds: nil,
            expiresAt: nil,
            sessionActivatedAt: timestamp,
            event: AgentEvent(
                id: "event-width-session",
                source: .codex,
                sessionID: "width-session",
                eventType: .tool,
                title: AgentEventKind.tool.title,
                createdAt: timestamp
            ),
            latestMessage: nil,
            latestUserMessage: nil,
            sessionTitle: nil,
            sessionMessage: nil,
            sessionUserMessage: nil,
            sessionActivity: nil,
            overlayDisplay: AgentOverlayDisplay(
                summaryKind: .tool,
                stateEntryID: "tool:codex:width-session:entry"
            )
        )
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func jsonArray<T: Encodable>(_ value: T) throws -> [Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [Any])
    }

    private func placementUpdateSuccess(
        _ params: Any,
        placementRevision: UInt64
    ) throws -> [String: Any] {
        var placement = try #require(params as? [String: Any])
        _ = try #require(
            placement.removeValue(forKey: "expected_revision") as? String
        )
        return [
            "ok": true,
            "revision": "state-\(placementRevision)",
            "overlay_placement_revision": String(placementRevision),
            "overlay_placement": placement,
            "overlay_placement_intent": NSNull(),
        ]
    }
}
