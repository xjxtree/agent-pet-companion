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

        try validateDisplayWidthPolicy()
        passed.append("geometry.display-width-policy")

        try validateActiveSessionBubbleContent()
        passed.append("bubble.active-session-content-retention")

        try validateLifecyclePresentationMatrix()
        passed.append("bubble.lifecycle-idle-through-failed")

        try validateNavigationCapabilityMatrix()
        passed.append("bubble.truthful-navigation-and-accessibility-order")

        try validateBubbleActionRouting()
        passed.append("bubble.session-group-close-hit-regions-and-deeplink")

        try await validateBubbleDisclosureState()
        passed.append("bubble.expand-preserves-consumed-sessions")

        try validateFrameTimeline()
        passed.append("timeline.authored-durations-and-playback")

        try await validateFramePipeline()
        passed.append("renderer.actor-lru-eager-ready-handoff")

        try await validatePointerMonitor()
        passed.append("pointer.permission-free-monitor")

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
            store.overlayDismissedBubbleEventIDs == ["codex-session-event", "pi-session-event"],
            "expand restored session rows that had already been consumed"
        )
    }

    private static func validateGeometry() throws {
        let visibleFrames = [
            CGRect(x: 0, y: 25, width: 1512, height: 934),
            CGRect(x: -1280, y: 0, width: 1280, height: 775)
        ]
        for visibleFrame in visibleFrames {
            for displayWidthPt: CGFloat in [100, 112, 300] {
                let localPetCenter = CGPoint(x: 420, y: 360)
                let menuScreenRect = OverlayGeometry.rect(
                    center: OverlayGeometry.menuScreenCenter(
                        petScreenCenter: localPetCenter,
                        displayWidthPt: displayWidthPt
                    ),
                    size: OverlayGeometry.menuHitSize
                )
                let bubbleSize = CGSize(width: OverlayGeometry.bubbleWidth, height: 76)
                let bubbleRect = OverlayGeometry.rect(
                    center: OverlayGeometry.bubbleScreenCenter(
                        bubbleSize: bubbleSize,
                        displayWidthPt: displayWidthPt,
                        petScreenCenter: localPetCenter,
                        screenFrame: visibleFrame
                    ),
                    size: bubbleSize
                )
                try require(
                    !bubbleRect.intersects(menuScreenRect),
                    "bubble panel overlaps the toggle hit region at \(displayWidthPt)pt"
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
                        displayWidthPt: displayWidthPt,
                        visibleFrame: visibleFrame,
                        clickMenuEnabled: true
                    )
                    let bounds = OverlayGeometry.petMovementScreenBounds(
                        displayWidthPt: displayWidthPt,
                        petScreenCenter: center,
                        clickMenuEnabled: true
                    )
                    try require(
                        visibleFrame.insetBy(dx: -0.5, dy: -0.5).contains(bounds),
                        "movement bounds escaped its frame at \(displayWidthPt)pt: \(bounds)"
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

    private static func validateDisplayWidthPolicy() throws {
        try require(
            OverlayGeometry.clampedDisplayWidthPt(1)
                == OverlayGeometry.minimumDisplayWidthPt,
            "minimum display-width clamp failed"
        )
        try require(
            OverlayGeometry.clampedDisplayWidthPt(999)
                == OverlayGeometry.maximumDisplayWidthPt,
            "maximum display-width clamp failed"
        )
        try require(
            OverlayGeometry.resolvedInitialDisplayWidthPt(
                persistedDisplayWidthPt: 80,
                hasPersistedPosition: false
            ) == 112,
            "never-positioned placement did not use the default width"
        )
        try require(
            OverlayGeometry.resolvedInitialDisplayWidthPt(
                persistedDisplayWidthPt: 80,
                hasPersistedPosition: true
            ) == 100,
            "legacy persisted display width was not clamped to the current minimum"
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
          },
          "overlay_display": {
            "summary_kind": "thinking",
            "navigation": {
              "capability": "agent_host",
              "session_open": true,
              "surface": "chatgpt_app",
              "terminal_app": null,
              "open_url": null
            }
          }
        }
        """#
        let state = try JSONDecoder().decode(ActiveAgentState.self, from: Data(stateJSON.utf8))
        let content = OverlayBubbleContent(state: state)
        guard let session = content.sessions.first else {
            throw AgentPetCompanionUIValidationFailure("active bubble omitted its session row")
        }

        try require(
            session.messageText == "Latest App Server message",
            "active bubble did not render the bounded assistant display message"
        )
        try require(
            session.activityText == "Verifying live activity synchronization",
            "active bubble did not render the bounded current activity detail"
        )
        try require(
            session.detailText == session.messageText,
            "active bubble rendered more than one body message"
        )
        var navigationFailure = session
        navigationFailure.navigationNotice = .failed
        try require(
            navigationFailure.detailText
                == APCLocalization.text(.overlaySessionNavigationFailed),
            "navigation feedback no longer replaced ordinary bubble body copy"
        )
        try require(
            content.agentName == "Codex",
            "active bubble omitted its Agent group title"
        )
        try require(session.sessionID == "session_validation", "active bubble omitted its session id")
        try require(
            session.sessionTitle == "Persistent Codex task title",
            "active bubble did not render the bounded session title"
        )
        try require(
            !session.detailText.contains("Keep the current conversation message visible."),
            "active bubble fell back to the user prompt"
        )
        try require(!session.statusText.isEmpty, "active bubble omitted its run status")
        try require(!session.actionLabel.isEmpty, "active bubble omitted its interaction action")

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
        let grouped = OverlayBubbleContent(
            source: .codex,
            states: [state, secondState],
            isExpanded: true
        )
        try require(grouped.sessions.count == 2, "same-Agent sessions were not grouped")
        try require(
            grouped.sessions.map(\.sessionTitle) == [
                "Persistent Codex task title",
                "Second Codex task title",
            ],
            "grouped session titles did not preserve their original values"
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

        let stacked = OverlayBubbleContent(
            source: .codex,
            states: [state, secondState],
            isExpanded: false
        )
        try require(stacked.visibleSessions.count == 1, "stacked group exposed hidden rows")
        try require(stacked.sessionCount == 2, "stacked group lost its full session count")
        try require(stacked.stackDecorationDepth > 0, "stacked group lost its depth treatment")
    }

    private static func validateBubbleActionRouting() throws {
        let sessions = (0 ..< 2).map { index in
            OverlaySessionContent(
                id: "validation-session-\(index)",
                source: .codex,
                sessionID: "validation-session-\(index)",
                eventType: .tool,
                sessionTitle: "Validation \(index)",
                messageText: "Running",
                statusText: "Running",
                navigation: AgentSessionNavigation(
                    capability: .agentHost,
                    sessionOpen: true,
                    surface: "chatgpt_app"
                )
            )
        }
        let content = OverlayBubbleContent(
            id: "validation-agent-codex",
            source: .codex,
            agentName: "Codex",
            sessions: sessions,
            isExpanded: false
        )
        // Every selectable text tier must keep the same routing contract: a
        // larger tier grows rows and header controls, so its hit regions are
        // re-measured rather than inherited from the standard tier.
        for fontScale in BubbleFontScale.allCases {
            let size = OverlayGeometry.resolvedBubbleSize(
                in: CGSize(width: 1512, height: 934),
                content: content,
                fontScale: fontScale
            )
            let bubbleRect = CGRect(origin: .zero, size: size)
            let closeRect = OverlayGeometry.bubbleCloseHitRect(
                in: bubbleRect,
                fontScale: fontScale
            )
            let groupRect = OverlayGeometry.bubbleGroupToggleHitRect(
                in: bubbleRect,
                content: content,
                fontScale: fontScale
            )
            let sessionRects = OverlayGeometry.bubbleSessionRects(
                in: bubbleRect,
                content: content,
                fontScale: fontScale
            )
            try require(sessionRects.count == 1, "bubble session hit regions did not match session rows")
            try require(!groupRect.isEmpty, "multi-session bubble omitted its group control hit region")
            try require(
                !sessionRects.contains(where: { $0.intersects(closeRect) }),
                "bubble session and close hit regions overlap"
            )
            try require(!groupRect.intersects(closeRect), "bubble group and close hit regions overlap")
            try require(
                !sessionRects.contains(where: { $0.intersects(groupRect) }),
                "bubble session and group hit regions overlap"
            )
            try require(
                closeRect.contains(CGPoint(x: bubbleRect.maxX - 12, y: 12)),
                "bubble close hit region missed its visible control"
            )
            try require(
                sessionRects[0].contains(CGPoint(x: sessionRects[0].midX, y: sessionRects[0].midY)),
                "bubble session hit region missed its visible row"
            )
        }

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
            AgentSessionDeepLink.url(source: .codex, sessionID: "thread-confirmed") == nil,
            "non-UUID session id was accepted for deep-link routing"
        )
        try require(
            AgentSessionDeepLink.url(source: .claudeCode, sessionID: "session") == nil,
            "unsupported agent source produced a Codex deep link"
        )
    }

    private static func validateLifecyclePresentationMatrix() throws {
        try require(
            OverlayBubbleProjection.contents(
                states: [],
                omittedCount: 0,
                dismissedSessionIDs: [],
                isExpanded: { _ in true }
            ).isEmpty,
            "idle state emitted a placeholder session bubble"
        )

        for eventType in AgentEventKind.allCases {
            let content = OverlaySessionContent(event: AgentEvent(
                id: "validation-\(eventType.rawValue)",
                source: .codex,
                sessionID: "validation-session",
                eventType: eventType,
                title: "arbitrary transport title",
                createdAt: "2026-07-23T00:00:00Z"
            ))
            let expectedStatus = APCLocalizedPresentation.eventTitle(eventType)
            try require(
                content.statusText == expectedStatus,
                "bubble status did not preserve the filtered event for \(eventType)"
            )
            try require(
                content.sessionTitle != content.statusText
                    && content.activityText.isEmpty
                    && content.messageText.isEmpty,
                "bubble inserted placeholder detail copy for \(eventType)"
            )
        }
    }

    private static func validateNavigationCapabilityMatrix() throws {
        func session(
            id: String,
            navigation: AgentSessionNavigation
        ) -> OverlaySessionContent {
            OverlaySessionContent(
                id: id,
                source: .codex,
                sessionID: id,
                eventType: .waiting,
                sessionTitle: "Session \(id)",
                activityText: APCLocalization.text(.overlayDetailNeedsInput),
                messageText: "A response is required",
                statusText: APCLocalizedPresentation.lifecycleTitle(.waiting),
                navigation: navigation
            )
        }

        let exact = session(
            id: "exact",
            navigation: AgentSessionNavigation(
                capability: .exactSession,
                sessionOpen: true,
                surface: "cli_terminal",
                terminalApp: "warp",
                openURL: "warp://session/A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4"
            )
        )
        let host = session(
            id: "host",
            navigation: AgentSessionNavigation(
                capability: .agentHost,
                sessionOpen: true,
                surface: "chatgpt_app"
            )
        )
        let malformed = session(
            id: "malformed",
            navigation: AgentSessionNavigation(
                capability: .exactSession,
                sessionOpen: true,
                surface: "chatgpt_app",
                routableSessionID: "unsafe/raw/session"
            )
        )
        let closed = session(
            id: "closed",
            navigation: AgentSessionNavigation(
                capability: .agentHost,
                sessionOpen: false,
                surface: "chatgpt_app"
            )
        )

        try require(exact.navigationCapability == .exactSession, "exact route was not retained")
        try require(host.navigationCapability == .agentHost, "host route was not retained")
        try require(
            malformed.navigationCapability == .unavailable && !malformed.canOpen,
            "malformed exact target remained actionable"
        )
        try require(
            closed.navigationCapability == .unavailable && !closed.canOpen,
            "closed session remained actionable"
        )
        try require(
            exact.actionLabel != host.actionLabel,
            "exact-session and host-level routes used the same action copy"
        )
        try require(
            exact.accessibilityReadingOrder == [
                "Codex",
                exact.surfaceLabel,
                "Session exact",
                APCLocalizedPresentation.lifecycleTitle(.waiting),
                "A response is required",
                exact.actionLabel,
            ],
            "VoiceOver order was not Agent, surface, session, status, visible message, action"
        )
    }

    private static func validateFrameTimeline() throws {
        let oneShot = FrameTimeline(
            durationsMS: [100, 200, 300],
            playback: PlaybackContract(
                mode: .burstThenSettle,
                entryRepeatCount: 1,
                settleFrameIndex: 1
            ),
            reducedMotionFrameIndex: 2
        )
        try require(oneShot.frameIndex(elapsedMS: 99) == 0, "first authored boundary drifted")
        try require(oneShot.frameIndex(elapsedMS: 100) == 1, "second authored frame started late")
        try require(oneShot.frameIndex(elapsedMS: 300) == 2, "third authored frame started late")
        try require(oneShot.frameIndex(elapsedMS: 600) == 1, "one-shot did not hold its settle frame")
        try require(oneShot.hasCompleted(elapsedMS: 600), "one-shot completion was not reported")

        let looping = FrameTimeline(
            durationsMS: [100, 200],
            playback: PlaybackContract(mode: .loop),
            reducedMotionFrameIndex: 1
        )
        try require(
            looping.frameIndex(elapsedMS: 300) == 0,
            "looping state did not wrap"
        )

        let periodic = FrameTimeline(
            durationsMS: [100, 100],
            playback: PlaybackContract(
                mode: .periodic,
                cooldownMS: [500, 500]
            ),
            reducedMotionFrameIndex: 1,
            periodicCooldownMS: 500
        )
        try require(
            periodic.frameIndex(elapsedMS: 250) == 1,
            "periodic cooldown did not hold its settle frame"
        )
        try require(
            periodic.frameIndex(elapsedMS: 700) == 0,
            "periodic playback did not restart after cooldown"
        )
        try require(
            periodic.frameIndex(elapsedMS: 0, reducedMotion: true) == 1,
            "reduced motion did not select the authored static frame"
        )

        var playback = FramePlaybackState(stateID: "start", enteredAt: 10)
        playback.enter(stateID: "start", at: 10.5)
        try require(
            playback.enteredAt == 10,
            "unchanged semantic state restarted playback"
        )
        playback.enter(stateID: "done", at: 11)
        try require(
            playback.frameIndex(at: 11, timeline: oneShot) == 0,
            "state entry did not reset playback"
        )
        try require(
            oneShot.resolvedFrameAfterStall(elapsedMS: 450) == 2,
            "stall recovery did not jump directly to the current authored frame"
        )
    }

    private static func validateFramePipeline() async throws {
        let timing = PetAnimationContract.defaultStates.first {
            $0.name == "tool"
        }!
        let urls = timing.frameDurationsMS.indices.map {
            URL(fileURLWithPath: "/virtual/frame-\($0).png")
        }
        let probe = UIValidationDecodeProbe()
        let pipeline = PetFramePipeline(
            memoryBudgetBytes: 32,
            catalog: { _, _ in PetFrameAssetCatalog(frameURLs: urls, coverURL: nil) },
            decoder: { probe.decode($0) }
        )
        let quality = QualityLevel.standard
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
        let request = PetFrameLoadRequest(
            pet: pet,
            stateName: "tool",
            timing: timing
        )
        let prepared = try await Task { @MainActor in
            try await pipeline.prepare(request)
        }.value

        try require(prepared.sourceKind == .eager, "V3 action did not use eager frame handoff")
        try require(
            prepared.sourceFrameCount == timing.frameDurationsMS.count,
            "source frame count did not match the timing contract"
        )
        try require(
            prepared.frameCount == timing.frameDurationsMS.count,
            "runtime frame count did not preserve every authored frame"
        )
        try require(
            prepared.readyFrameCount == timing.frameDurationsMS.count,
            "eager handoff did not contain the complete authored state"
        )
        try require(
            prepared.timeline == FrameTimeline(state: timing),
            "prepared timeline diverged from the package timing contract"
        )
        let readsAfterPrepare = probe.snapshot().count
        for index in 0..<100 {
            _ = prepared.readyFrame(at: index % max(1, prepared.frameCount))
        }
        try require(
            probe.snapshot().count == readsAfterPrepare,
            "ready-frame lookup performed decode or file work"
        )

        let metrics = await pipeline.cacheMetrics()
        try require(metrics.byteCount <= 32, "LRU exceeded byte budget")
        try require(metrics.maximumConcurrentDecodes == 1, "decode queue was not bounded")
        try require(!probe.snapshot().decodedOnMain, "frame decode executed on the main thread")
    }

    private static func validatePointerMonitor() async throws {
        let result = await MainActor.run {
            let monitor = OverlayPointerEventMonitor()
            let idleUsesPolling = monitor.usesPolling
            let idleIsRunning = monitor.isRunning
            monitor.start {}
            let activeUsesPolling = monitor.usesPolling
            let activeIsRunning = monitor.isRunning
            monitor.stop()
            return (
                idleUsesPolling: idleUsesPolling,
                idleIsRunning: idleIsRunning,
                activeUsesPolling: activeUsesPolling,
                activeIsRunning: activeIsRunning,
                stoppedIsRunning: monitor.isRunning,
                pollingInterval: OverlayPointerEventMonitor.pollingInterval,
                hasMouseMoved: OverlayPointerEventMonitor.eventMask.contains(.mouseMoved),
                hasMouseDown: OverlayPointerEventMonitor.eventMask.contains(.leftMouseDown),
                hasMouseUp: OverlayPointerEventMonitor.eventMask.contains(.leftMouseUp),
                hasDrag: OverlayPointerEventMonitor.eventMask.contains(.leftMouseDragged)
            )
        }
        try require(!result.idleUsesPolling, "idle pointer monitor unexpectedly polls")
        try require(!result.idleIsRunning, "pointer monitor starts while not needed")
        try require(result.activeUsesPolling, "active pointer monitor does not poll")
        try require(result.activeIsRunning, "active pointer monitor is not running")
        try require(!result.stoppedIsRunning, "stopped pointer monitor is still running")
        try require(
            result.pollingInterval == 1.0 / 120.0,
            "pointer monitor does not use the authored permission-free sampling interval"
        )
        try require(
            result.hasMouseMoved && result.hasMouseDown && result.hasMouseUp
                && !result.hasDrag,
            "local pointer mask must track hover/press/release without duplicating drag delivery"
        )
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
