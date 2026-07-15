import AgentPetCompanionCore
import AppKit
import CoreImage
import Foundation

public struct AgentPetCompanionUIValidationFailure: LocalizedError, Sendable {
    public let errorDescription: String?

    init(_ description: String) {
        errorDescription = description
    }
}

public enum AgentPetCompanionUIValidationContract {
    public static func run() async throws -> [String] {
        var passed: [String] = []

        try validateGeometry()
        passed.append("geometry.complete-interactive-bounds")

        try validateMultiDisplaySelection()
        passed.append("geometry.current-pointer-display")

        try validateScalePolicy()
        passed.append("geometry.scale-policy")

        try validateActiveSessionBubbleContent()
        passed.append("bubble.active-session-content-retention")

        try validateBubbleActionRouting()
        passed.append("bubble.open-close-hit-regions-and-deeplink")

        try await validateBubbleDisclosureState()
        passed.append("bubble.expand-clears-all-dismissal-layers")

        try validateScheduler()
        passed.append("scheduler.loop-and-one-shot")

        try await validateAccessibleResize()
        passed.append("accessibility.resize-slider-keyboard-actions")

        try await validateFramePipeline()
        passed.append("renderer.actor-lru-ring-ready-handoff")

        try await validatePointerMonitor()
        passed.append("pointer.event-driven-monitor")

        return passed
    }

    @MainActor
    private static func validateBubbleDisclosureState() throws {
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            )
        )
        store.overlayBubbleDismissed = true
        store.overlayDismissedBubbleEventIDs = ["codex-session-event", "pi-session-event"]

        store.toggleOverlayBubble()

        try require(!store.overlayBubbleDismissed, "expand left the global bubble dismissal active")
        try require(
            store.overlayDismissedBubbleEventIDs.isEmpty,
            "expand left session-level bubble dismissals active"
        )
    }

    private static func validateGeometry() throws {
        let visibleFrames = [
            CGRect(x: 0, y: 25, width: 1512, height: 934),
            CGRect(x: -1280, y: 0, width: 1280, height: 775)
        ]
        for visibleFrame in visibleFrames {
            for scale: CGFloat in [0.10, 0.72, 1.8] {
                let localPetCenter = CGPoint(x: 420, y: 360)
                let resizeCenter = OverlayGeometry.resizeCenter(
                    petCenter: localPetCenter,
                    scale: scale
                )
                let menuCenter = OverlayGeometry.menuCenter(
                    petCenter: localPetCenter,
                    scale: scale
                )
                try require(
                    abs(resizeCenter.x - menuCenter.x) < 0.001,
                    "resize handle left the pet-side control column at scale \(scale)"
                )
                try require(
                    !OverlayGeometry.rect(center: resizeCenter, size: OverlayGeometry.resizeHitSize)
                        .intersects(OverlayGeometry.rect(center: menuCenter, size: OverlayGeometry.menuHitSize)),
                    "resize and bubble-toggle hit regions overlap at scale \(scale)"
                )

                let menuScreenRect = OverlayGeometry.rect(
                    center: OverlayGeometry.menuScreenCenter(
                        petScreenCenter: localPetCenter,
                        scale: scale
                    ),
                    size: OverlayGeometry.menuHitSize
                )
                let resizeScreenRect = OverlayGeometry.rect(
                    center: OverlayGeometry.resizeScreenCenter(
                        petScreenCenter: localPetCenter,
                        scale: scale
                    ),
                    size: OverlayGeometry.resizeHitSize
                )
                let activationRect = OverlayGeometry.pointerNearPetScreenRect(
                    scale: scale,
                    petScreenCenter: localPetCenter,
                    clickMenuEnabled: true
                )
                try require(
                    activationRect.contains(menuScreenRect.insetBy(dx: -8, dy: -8)),
                    "bubble toggle lacks a preactivation margin at scale \(scale)"
                )
                try require(
                    activationRect.contains(resizeScreenRect.insetBy(dx: -8, dy: -8)),
                    "resize handle lacks a preactivation margin at scale \(scale)"
                )

                let bubbleSize = CGSize(width: OverlayGeometry.bubbleWidth, height: 76)
                let bubbleRect = OverlayGeometry.rect(
                    center: OverlayGeometry.bubbleScreenCenter(
                        bubbleSize: bubbleSize,
                        scale: scale,
                        petScreenCenter: localPetCenter,
                        screenFrame: visibleFrame
                    ),
                    size: bubbleSize
                )
                try require(
                    !bubbleRect.intersects(menuScreenRect),
                    "bubble panel overlaps the toggle hit region at scale \(scale)"
                )

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
                    try require(
                        visibleFrame.insetBy(dx: -0.5, dy: -0.5).contains(bounds),
                        "movement bounds escaped its frame at scale \(scale): \(bounds)"
                    )
                }
            }
        }

        let fullScreen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let systemVisibleFrame = CGRect(x: 0, y: 60, width: 1728, height: 1024)
        let movementFrame = OverlayGeometry.petMovementFrame(
            screenFrame: fullScreen,
            visibleFrame: systemVisibleFrame
        )
        try require(
            movementFrame.minY == fullScreen.minY,
            "movement frame still excludes the Dock reservation"
        )
        try require(
            movementFrame.maxY == systemVisibleFrame.maxY,
            "movement frame no longer protects the menu-bar strip"
        )
    }

    private static func validateMultiDisplaySelection() throws {
        let primary = OverlayDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 25, width: 1512, height: 934),
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
        try require(target == secondary, "drag target did not follow the current pointer display")
    }

    private static func validateScalePolicy() throws {
        try require(
            OverlayGeometry.clampedScale(0.01) == OverlayGeometry.minimumScale,
            "minimum scale clamp failed"
        )
        try require(
            OverlayGeometry.clampedScale(9) == OverlayGeometry.maximumScale,
            "maximum scale clamp failed"
        )
        try require(
            OverlayGeometry.resolvedInitialScale(
                persistedScale: 0.12,
                hasPersistedPosition: false
            ) == 0.72,
            "never-positioned placement did not use calibrated scale"
        )
        try require(
            OverlayGeometry.resolvedInitialScale(
                persistedScale: 0.12,
                hasPersistedPosition: true
            ) == 0.12,
            "legacy nonzero placement scale was overwritten"
        )
    }

    private static func validateActiveSessionBubbleContent() throws {
        let stateJSON = #"""
        {
          "state": "tool",
          "official_status": "running",
          "source": "codex",
          "session_id": "session_validation",
          "session_active": true,
          "source_session_sequence": 3,
          "priority": 300,
          "lease_seconds": null,
          "expires_at": null,
          "event": {
            "id": "evt_tool",
            "source": "codex",
            "session_id": "session_validation",
            "event_type": "tool",
            "title": "Executing tool",
            "detail": null,
            "payload_json": {
              "schema_version": "apc.agent-event.v1",
              "source_event": "PreToolUse",
              "session_active": true,
              "project_label": "agent-pet-companion"
            },
            "created_at": "2026-07-13T00:00:03Z"
          },
          "latest_message": {
            "id": "evt_prompt",
            "source": "codex",
            "session_id": "session_validation",
            "event_type": "start",
            "title": "Started",
            "detail": null,
            "payload_json": {
              "schema_version": "apc.agent-event.v1",
              "source_event": "UserPromptSubmit",
              "session_active": true,
              "message_role": "user",
              "message_content": "Keep the current conversation message visible.",
              "project_label": "agent-pet-companion"
            },
            "created_at": "2026-07-13T00:00:01Z"
          },
          "session_title": "Persistent Codex task title",
          "session_message": {
            "role": "assistant",
            "content": "Latest App Server message"
          },
          "session_activity": {
            "kind": "thinking",
            "content": "Verifying live activity synchronization"
          }
        }
        """#
        let state = try JSONDecoder().decode(ActiveAgentState.self, from: Data(stateJSON.utf8))
        let content = OverlayBubbleContent(state: state)
        guard let session = content.sessions.first else {
            throw AgentPetCompanionUIValidationFailure("active bubble omitted its session row")
        }

        try require(
            session.messageText == "Verifying live activity synchronization",
            "active bubble did not prefer the current activity over an earlier Agent message"
        )
        try require(
            content.agentName == "Codex",
            "active bubble omitted its Agent group title"
        )
        try require(session.sessionID == "session_validation", "active bubble omitted its session id")
        try require(
            session.sessionTitle == "Persistent Codex task title",
            "active bubble omitted its session title"
        )
        try require(!session.statusText.isEmpty, "active bubble omitted its run status")
        try require(!session.actionLabel.isEmpty, "active bubble omitted its interaction action")
        try require(
            !(OverlayBubbleContent.idle.sessions.first?.messageText ?? "").contains("等待 Agent 事件"),
            "idle copy regressed to the misleading wait-for-event message"
        )

        let secondStateJSON = stateJSON
            .replacingOccurrences(of: "session_validation", with: "session_validation_2")
            .replacingOccurrences(of: "evt_tool", with: "evt_tool_2")
            .replacingOccurrences(
                of: "Persistent Codex task title",
                with: "Second Codex task title"
            )
        let secondState = try JSONDecoder().decode(
            ActiveAgentState.self,
            from: Data(secondStateJSON.utf8)
        )
        let grouped = OverlayBubbleContent(source: .codex, states: [state, secondState])
        try require(grouped.sessions.count == 2, "same-Agent sessions were not grouped")
        try require(
            grouped.sessions.map(\.sessionTitle) == [
                "Persistent Codex task title",
                "Second Codex task title",
            ],
            "grouped session titles lost their visual identity"
        )
        let groupedSize = OverlayGeometry.resolvedBubbleSize(
            in: CGSize(width: 1512, height: 934),
            content: grouped
        )
        let groupedRects = OverlayGeometry.bubbleSessionRects(
            in: CGRect(origin: .zero, size: groupedSize),
            content: grouped
        )
        try require(
            groupedRects.count == 2 && !groupedRects[0].intersects(groupedRects[1]),
            "grouped session rows overlap or lack distinct hit regions"
        )
    }

    private static func validateBubbleActionRouting() throws {
        let content = OverlayBubbleContent.idle
        let size = OverlayGeometry.resolvedBubbleSize(
            in: CGSize(width: 1512, height: 934),
            content: content
        )
        let bubbleRect = CGRect(origin: .zero, size: size)
        let closeRect = OverlayGeometry.bubbleCloseHitRect(in: bubbleRect)
        let sessionRects = OverlayGeometry.bubbleSessionRects(in: bubbleRect, content: content)
        try require(sessionRects.count == 1, "bubble session hit regions did not match session rows")
        try require(
            !sessionRects.contains(where: { $0.intersects(closeRect) }),
            "bubble session and close hit regions overlap"
        )
        try require(
            closeRect.contains(CGPoint(x: bubbleRect.maxX - 12, y: 12)),
            "bubble close hit region missed its visible control"
        )
        try require(
            sessionRects[0].contains(CGPoint(x: sessionRects[0].midX, y: sessionRects[0].midY)),
            "bubble session hit region missed its visible row"
        )

        try require(
            AgentSessionDeepLink.url(source: .codex, sessionID: "019f5b0f-88ff-7413-8953-29de4ed0951c")?.absoluteString
                == "codex://threads/019f5b0f-88ff-7413-8953-29de4ed0951c",
            "Codex session did not resolve to the ChatGPT task deep link"
        )
        try require(
            AgentSessionDeepLink.url(source: .codex, sessionID: "unsafe/session") == nil,
            "unsafe session id was accepted for deep-link routing"
        )
        try require(
            AgentSessionDeepLink.url(source: .claudeCode, sessionID: "session") == nil,
            "unsupported agent source produced a Codex deep link"
        )
    }

    private static func validateScheduler() throws {
        let oneShot = FrameScheduler(fps: 12, frameCount: 4, loops: false)
        try require(oneShot.frameIndex(elapsedSeconds: 10) == 3, "one-shot did not stop at final frame")
        try require(oneShot.hasCompleted(elapsedSeconds: 10), "one-shot completion was not reported")

        let looping = FrameScheduler(fps: 12, frameCount: 4, loops: true)
        try require(
            looping.frameIndex(elapsedSeconds: 4.0 / 12.0) == 0,
            "looping state did not wrap"
        )

        var playback = FramePlaybackState(stateID: "start", enteredAt: 10)
        playback.enter(stateID: "done", at: 11)
        try require(
            playback.frameIndex(at: 11, scheduler: oneShot) == 0,
            "state entry did not reset playback"
        )
    }

    private static func validateAccessibleResize() async throws {
        let result = await MainActor.run {
            let view = OverlayResizeAccessibilityView(
                frame: CGRect(x: 0, y: 0, width: 38, height: 38)
            )
            var steps: [CGFloat] = []
            view.scale = 0.72
            view.onScaleStep = { steps.append($0) }
            view.keyDown(with: NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "+",
                charactersIgnoringModifiers: "+",
                isARepeat: false,
                keyCode: 24
            )!)
            let incremented = view.accessibilityPerformIncrement()
            let decremented = view.accessibilityPerformDecrement()
            return (
                acceptsFocus: view.acceptsFirstResponder,
                role: view.accessibilityRole(),
                value: (view.accessibilityValue() as? NSNumber)?.doubleValue,
                valueDescription: view.accessibilityValueDescription(),
                steps: steps,
                incremented: incremented,
                decremented: decremented
            )
        }
        try require(result.acceptsFocus, "resize control is not focusable")
        try require(result.role == .slider, "resize control is not exposed as an AX slider")
        try require(result.value == 0.72, "resize AX value is missing")
        try require(result.valueDescription == "72%", "resize AX value description is missing")
        try require(result.incremented && result.decremented, "resize AX actions failed")
        try require(
            result.steps == [0.05, 0.05, -0.05],
            "keyboard and AX actions did not share the five-percent step path"
        )
    }

    private static func validateFramePipeline() async throws {
        let urls = (0..<20).map { URL(fileURLWithPath: "/virtual/frame-\($0).png") }
        let probe = UIValidationDecodeProbe()
        let pipeline = PetFramePipeline(
            memoryBudgetBytes: 32,
            originalWindowSize: 7,
            catalog: { _, _ in PetFrameAssetCatalog(frameURLs: urls, coverURL: nil) },
            decoder: { probe.decode($0) }
        )
        let quality = QualityLevel.original
        let pet = PetSummary(
            id: "pet_validation",
            name: "Validation",
            style: "pixel",
            quality: quality,
            renderSize: quality.renderSize,
            petpackPath: "/virtual/validation.petpack",
            coverPath: "",
            active: true,
            createdAt: "2026-07-10T00:00:00Z"
        )
        let request = PetFrameLoadRequest(pet: pet, stateName: "tool", fps: 12, loops: true)
        let prepared = try await Task { @MainActor in
            try await pipeline.prepare(request)
        }.value

        try require(prepared.sourceKind == .ring, "original quality did not select ring cache")
        try require(prepared.readyFrameCount <= 7, "initial ring exceeded its window")
        let readsAfterPrepare = probe.snapshot().count
        for index in 0..<100 {
            _ = prepared.readyFrame(at: index % max(1, prepared.frameCount))
        }
        try require(
            probe.snapshot().count == readsAfterPrepare,
            "ready-frame lookup performed decode or file work"
        )

        let advanced = try await pipeline.prefetch(prepared, around: 12)
        try require(advanced.readyFrame(at: 12) != nil, "ring prefetch missed requested frame")
        try require(advanced.readyFrameCount <= 7, "advanced ring exceeded its window")
        let metrics = await pipeline.cacheMetrics()
        try require(metrics.byteCount <= 32, "LRU exceeded byte budget")
        try require(metrics.maximumConcurrentDecodes == 1, "decode queue was not bounded")
        try require(!probe.snapshot().decodedOnMain, "frame decode executed on the main thread")
    }

    private static func validatePointerMonitor() async throws {
        let result = await MainActor.run {
            let monitor = OverlayPointerEventMonitor()
            return (
                usesPolling: monitor.usesPolling,
                isRunning: monitor.isRunning,
                hasMouseMoved: OverlayPointerEventMonitor.eventMask.contains(.mouseMoved),
                hasDrag: OverlayPointerEventMonitor.eventMask.contains(.leftMouseDragged)
            )
        }
        try require(!result.usesPolling, "pointer monitor still uses polling")
        try require(!result.isRunning, "pointer monitor starts while not needed")
        try require(result.hasMouseMoved && result.hasDrag, "pointer event mask is incomplete")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw AgentPetCompanionUIValidationFailure(message) }
    }
}

private final class UIValidationDecodeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var decodedOnMain = false

    func decode(_ url: URL) -> PetDecodedFrame {
        lock.lock()
        count += 1
        decodedOnMain = decodedOnMain || Thread.isMainThread
        lock.unlock()
        return PetDecodedFrame(
            image: CIImage(color: .white).cropped(
                to: CGRect(x: 0, y: 0, width: 2, height: 2)
            ),
            pixelWidth: 2,
            pixelHeight: 2
        )
    }

    func snapshot() -> (count: Int, decodedOnMain: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (count, decodedOnMain)
    }
}
