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

    private static func validateGeometry() throws {
        let visibleFrames = [
            CGRect(x: 0, y: 25, width: 1512, height: 934),
            CGRect(x: -1280, y: 0, width: 1280, height: 775)
        ]
        for visibleFrame in visibleFrames {
            for scale: CGFloat in [0.10, 0.72, 1.8] {
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
                    try require(
                        visibleFrame.insetBy(dx: -0.5, dy: -0.5).contains(bounds),
                        "interactive bounds escaped the visible frame at scale \(scale): \(bounds)"
                    )
                }
            }
        }
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
