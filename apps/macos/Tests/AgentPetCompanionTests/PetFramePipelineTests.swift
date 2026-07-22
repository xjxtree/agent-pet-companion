import AgentPetCompanionCore
import AppKit
import CoreImage
import Testing
@testable import AgentPetCompanion

@Suite
struct PetFramePipelineTests {
    @Test
    func reducedMotionPinsPlaybackToRepresentativeFrameAndPauses() {
        #expect(PetMotionPresentation.playbackTime(
            now: 25,
            enteredAt: 10,
            reduceMotion: true
        ) == 10)
        #expect(PetMotionPresentation.playbackTime(
            now: 25,
            enteredAt: 10,
            reduceMotion: false
        ) == 25)
        #expect(PetMotionPresentation.shouldPauseAfterRepresentativeFrame(
            reduceMotion: true,
            frameCount: 12
        ))
        #expect(!PetMotionPresentation.shouldPauseAfterRepresentativeFrame(
            reduceMotion: false,
            frameCount: 12
        ))
    }

    @MainActor
    @Test
    func presentationCoordinatorRejectsOutOfOrderDrawableCallbacks() throws {
        let coordinator = PetFramePresentationCoordinator()
        let context = PetFramePresentationContext(
            renderGeneration: UUID(),
            stateEntryID: "tool:session-a"
        )
        coordinator.activate(context)
        let earlier = try #require(coordinator.reserve(for: context))
        let later = try #require(coordinator.reserve(for: context))
        let earlierMask = try presentationHitTest(alpha: 64)
        let laterMask = try presentationHitTest(alpha: 255)

        #expect(later.sequence > earlier.sequence)
        #expect(coordinator.resolve(
            .presented(laterMask),
            token: later
        ) == .publish(laterMask))
        #expect(coordinator.resolve(
            .presented(earlierMask),
            token: earlier
        ) == .rejected)
        #expect(coordinator.snapshot.hitTest == laterMask)
        #expect(coordinator.snapshot.latestAcceptedSequence == later.sequence)
    }

    @MainActor
    @Test
    func presentationCoordinatorRejectsOldStateCallbacksWhenGenerationIsReused() throws {
        let coordinator = PetFramePresentationCoordinator()
        let reusedGeneration = UUID()
        let oldContext = PetFramePresentationContext(
            renderGeneration: reusedGeneration,
            stateEntryID: "tool:session-a:activation-1"
        )
        coordinator.activate(oldContext)
        let stale = try #require(coordinator.reserve(for: oldContext))

        coordinator.invalidate()
        let currentContext = PetFramePresentationContext(
            renderGeneration: reusedGeneration,
            stateEntryID: "tool:session-b:activation-2"
        )
        coordinator.activate(currentContext)
        let current = try #require(coordinator.reserve(for: currentContext))
        let staleMask = try presentationHitTest(alpha: 64)
        let currentMask = try presentationHitTest(alpha: 255)

        #expect(current.epoch > stale.epoch)
        #expect(current.sequence > stale.sequence)
        #expect(coordinator.reserve(for: oldContext) == nil)
        #expect(coordinator.resolve(
            .presented(staleMask),
            token: stale
        ) == .rejected)
        #expect(coordinator.resolve(
            .presented(currentMask),
            token: current
        ) == .publish(currentMask))
    }

    @MainActor
    @Test
    func rendererSuspensionInvalidatesLatePresentedCallbacks() throws {
        let coordinator = PetFramePresentationCoordinator()
        let context = PetFramePresentationContext(
            renderGeneration: UUID(),
            stateEntryID: "waiting:session-a"
        )
        coordinator.activate(context)
        let inFlight = try #require(coordinator.reserve(for: context))
        let mask = try presentationHitTest(alpha: 255)
        let activeEpoch = coordinator.snapshot.epoch

        // PetMetalFrameRenderer uses invalidation for hide, dismantle, and
        // explicit lifecycle suspension.
        coordinator.invalidate()

        #expect(coordinator.snapshot.epoch > activeEpoch)
        #expect(coordinator.snapshot.context == nil)
        #expect(coordinator.snapshot.hitTest == nil)
        #expect(coordinator.resolve(
            .presented(mask),
            token: inFlight
        ) == .rejected)
    }

    @MainActor
    @Test
    func oneShotFinalFrameMayPublishAfterDisplayLinkPause() throws {
        let coordinator = PetFramePresentationCoordinator()
        let context = PetFramePresentationContext(
            renderGeneration: UUID(),
            stateEntryID: "done:session-a:activation-1"
        )
        coordinator.activate(context)
        let finalSubmission = try #require(coordinator.reserve(for: context))
        let finalMask = try presentationHitTest(alpha: 255)

        // Pausing MTKView after submitting the one-shot final frame is not a
        // renderer suspension, so its pending presented callback stays valid.
        #expect(coordinator.resolve(
            .presented(finalMask),
            token: finalSubmission
        ) == .publish(finalMask))
        #expect(coordinator.snapshot.hitTest == finalMask)
    }

    @MainActor
    @Test
    func replacementHandlerReplaysOnlyTheLastAcceptedPresentation() throws {
        let coordinator = PetFramePresentationCoordinator()
        let context = PetFramePresentationContext(
            renderGeneration: UUID(),
            stateEntryID: "tool:handler-replacement"
        )
        coordinator.activate(context)
        let submission = try #require(coordinator.reserve(for: context))
        let presentedMask = try presentationHitTest(alpha: 255)
        #expect(coordinator.resolve(
            .presented(presentedMask),
            token: submission
        ) == .publish(presentedMask))

        var replayed: [OverlayPetFrameHitTest?] = []
        coordinator.replayCurrent { replayed.append($0) }

        #expect(replayed == [presentedMask])
    }

    @MainActor
    @Test
    func presentedNilMaskAdvancesSequenceAndBlocksOlderMask() throws {
        let coordinator = PetFramePresentationCoordinator()
        let context = PetFramePresentationContext(
            renderGeneration: UUID(),
            stateEntryID: "tool:transparent-frame"
        )
        coordinator.activate(context)
        let opaqueSubmission = try #require(coordinator.reserve(for: context))
        let transparentSubmission = try #require(coordinator.reserve(for: context))
        let opaqueMask = try presentationHitTest(alpha: 255)

        #expect(coordinator.resolve(
            .presented(opaqueMask),
            token: opaqueSubmission
        ) == .publish(opaqueMask))
        #expect(coordinator.resolve(
            .presented(nil),
            token: transparentSubmission
        ) == PetFramePresentationDecision.publish(nil))
        #expect(coordinator.snapshot.hitTest == nil)
        #expect(coordinator.snapshot.latestAcceptedSequence == transparentSubmission.sequence)
        #expect(coordinator.resolve(
            .presented(opaqueMask),
            token: opaqueSubmission
        ) == .rejected)
    }

    @MainActor
    @Test
    func gpuFailureDoesNotSupersedeTheLastActuallyPresentedMask() throws {
        let coordinator = PetFramePresentationCoordinator()
        let context = PetFramePresentationContext(
            renderGeneration: UUID(),
            stateEntryID: "tool:gpu-failure"
        )
        coordinator.activate(context)
        let first = try #require(coordinator.reserve(for: context))
        let presentedBeforeFailure = try #require(coordinator.reserve(for: context))
        let failed = try #require(coordinator.reserve(for: context))
        let firstMask = try presentationHitTest(alpha: 255)
        let nextPresentedMask = try presentationHitTest(alpha: 64)

        #expect(coordinator.resolve(
            .presented(firstMask),
            token: first
        ) == .publish(firstMask))
        #expect(coordinator.resolve(.failed, token: failed)
            == .acceptedUnchanged)
        #expect(coordinator.snapshot.hitTest == firstMask)
        #expect(coordinator.snapshot.latestAcceptedSequence == first.sequence)
        // A failure callback may reach MainActor before an earlier drawable's
        // presented callback. Failure therefore cannot advance the presented
        // sequence or suppress that real presentation.
        #expect(coordinator.resolve(
            .presented(nextPresentedMask),
            token: presentedBeforeFailure
        ) == .publish(nextPresentedMask))
        #expect(coordinator.snapshot.hitTest == nextPresentedMask)
        #expect(coordinator.snapshot.latestAcceptedSequence == presentedBeforeFailure.sequence)
    }

    @Test
    func testDrawLookupNeverReadsDisk() async throws {
        let probe = FrameDecoderProbe()
        let pipeline = makePipeline(probe: probe, frameCount: 3)
        let prepared = try await pipeline.prepare(request(quality: .standard, stateName: "tool"))
        let readsAfterPrepare = probe.decodeCount

        for index in 0..<20 {
            _ = prepared.readyFrame(at: index % 3)
        }

        #expect(probe.decodeCount == readsAfterPrepare)
    }

    @MainActor
    @Test
    func testDecodeWorkIsNotMainActor() async throws {
        let probe = FrameDecoderProbe()
        let pipeline = makePipeline(probe: probe, frameCount: 2)

        _ = try await pipeline.prepare(request(quality: .standard, stateName: "tool"))

        #expect(!probe.didDecodeOnMainThread)
    }

    @Test
    func testLRURespectsByteBudget() async throws {
        let probe = FrameDecoderProbe(pixelWidth: 2, pixelHeight: 2)
        let pipeline = makePipeline(
            probe: probe,
            frameCount: 6,
            memoryBudgetBytes: 32
        )

        _ = try await pipeline.prepare(request(quality: .standard, stateName: "tool"))
        let metrics = await pipeline.cacheMetrics()

        #expect(metrics.byteCount <= 32)
        #expect(metrics.frameCount <= 2)
        #expect(metrics.maximumConcurrentDecodes <= 1)
    }

    @Test
    func testOriginalQualityKeepsRingWindow() async throws {
        let probe = FrameDecoderProbe()
        let pipeline = makePipeline(
            probe: probe,
            frameCount: 30,
            originalWindowSize: 7
        )

        let prepared = try await pipeline.prepare(request(quality: .original, stateName: "tool"))
        let advanced = try await pipeline.prefetch(prepared, around: 12)

        #expect(prepared.sourceKind == .ring)
        #expect(prepared.readyFrameCount <= 7)
        #expect(advanced.readyFrameCount <= 7)
        #expect(advanced.readyFrame(at: 12) != nil)
    }

    @Test
    func testPreparedFramesExposeStableUnionOfVisibleActionBounds() async throws {
        let urls = (0..<2).map { URL(fileURLWithPath: "/virtual/visible-\($0).png") }
        let pipeline = PetFramePipeline(
            memoryBudgetBytes: 1_024 * 1_024,
            catalog: { _, _ in PetFrameAssetCatalog(frameURLs: urls, coverURL: nil) },
            decoder: { url in
                let index = url.deletingPathExtension().lastPathComponent.hasSuffix("1") ? 1 : 0
                let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 120))
                return PetDecodedFrame(
                    image: image,
                    pixelWidth: 100,
                    pixelHeight: 120,
                    visibleBounds: index == 0
                        ? CGRect(x: 10, y: 15, width: 70, height: 80)
                        : CGRect(x: 20, y: 5, width: 65, height: 110)
                )
            }
        )

        let prepared = try await pipeline.prepare(request(quality: .standard, stateName: "tool"))

        #expect(prepared.visualEnvelope == OverlayPetVisualEnvelope(
            canvasSize: CGSize(width: 100, height: 120),
            visibleBounds: CGRect(x: 10, y: 5, width: 75, height: 110)
        ))
    }

    @Test
    func testPlaybackRestartKeepsPreparedFramesAndGeneration() async throws {
        let pipeline = makePipeline(probe: FrameDecoderProbe(), frameCount: 2)
        let prepared = try await pipeline.prepare(request(quality: .standard, stateName: "tool"))
        let handoff = PetFrameRenderHandoff()
        let generation = UUID()

        handoff.begin(generation: generation, stateID: "tool:first", enteredAt: 10)
        #expect(handoff.publish(prepared, generation: generation))
        #expect(handoff.lookup(at: 10).frame != nil)

        handoff.restartPlayback(stateID: "tool:second", enteredAt: 20)
        let restarted = handoff.lookup(at: 20)

        #expect(restarted.generation == generation)
        #expect(restarted.frame != nil)
        #expect(handoff.prepared(generation: generation) != nil)
    }

    @Test
    func testOneShotPlaybackDoesNotReplayAfterCanonicalABARotation() {
        var history = PetPlaybackEntryHistory(capacity: 8)
        let sessionA = "start:codex:session-a:activation-1"
        let sessionB = "start:codex:session-b:activation-1"

        #expect(history.transition(to: sessionA, loops: false).shouldRestartPlayback)
        #expect(history.transition(to: sessionB, loops: false).shouldRestartPlayback)

        let rotatedBack = history.transition(to: sessionA, loops: false)
        #expect(rotatedBack.isNewEntry)
        #expect(!rotatedBack.shouldRestartPlayback)
    }

    @Test
    func testOneShotPlaybackReplaysForGenuineNewActivation() {
        var history = PetPlaybackEntryHistory(capacity: 8)
        let firstActivation = "start:codex:session-a:activation-1"
        let otherSession = "start:codex:session-b:activation-1"
        let nextActivation = "start:codex:session-a:activation-2"

        #expect(history.transition(to: firstActivation, loops: false).shouldRestartPlayback)
        #expect(history.transition(to: otherSession, loops: false).shouldRestartPlayback)
        #expect(history.transition(to: firstActivation, loops: false).isNewEntry)
        #expect(history.transition(to: nextActivation, loops: false).shouldRestartPlayback)
    }

    @Test
    func testLoopingPlaybackRetainsCurrentEntryRestartSemantics() {
        var history = PetPlaybackEntryHistory(capacity: 8)

        #expect(history.transition(to: "tool", loops: true).shouldRestartPlayback)
        let duplicate = history.transition(to: "tool", loops: true)
        #expect(!duplicate.isNewEntry)
        #expect(!duplicate.shouldRestartPlayback)
        #expect(history.transition(to: "waiting", loops: true).shouldRestartPlayback)
        #expect(history.transition(to: "tool", loops: true).shouldRestartPlayback)
    }

    @Test
    func testOneShotPlaybackHistoryIsBounded() {
        var history = PetPlaybackEntryHistory(capacity: 2)

        #expect(history.transition(to: "start:a:1", loops: false).shouldRestartPlayback)
        #expect(history.transition(to: "start:b:1", loops: false).shouldRestartPlayback)
        #expect(history.transition(to: "start:c:1", loops: false).shouldRestartPlayback)
        #expect(history.transition(to: "start:a:1", loops: false).shouldRestartPlayback)
    }

    @Test
    func testAlphaVisibleBoundsFindsOnlyOpaquePixels() throws {
        let width = 8
        let height = 10
        let bytesPerRow = width * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * height)
        let image = rgba.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 2, y: 3, width: 4, height: 5))
            return context.makeImage()
        }
        let decoded = try #require(image)

        #expect(PetFramePipeline.alphaVisibleBounds(of: decoded) == CGRect(
            x: 2,
            y: 3,
            width: 4,
            height: 5
        ))
    }

    @Test
    func alphaHitMaskPreservesTransparentHolesThresholdAndBottomLeftLookup() throws {
        let width = 3
        let height = 2
        // CGImage provider rows are top-to-bottom. Alpha 2 is deliberately at
        // the interaction threshold and must remain click-through; alpha 3 is
        // the first value considered interactive.
        let alphaRows: [UInt8] = [
            0, 2, 3,
            255, 0, 1,
        ]
        var rgba: [UInt8] = []
        for alpha in alphaRows {
            rgba.append(contentsOf: [0, 0, 0, alpha])
        }
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let image = try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let mask = try #require(PetFramePipeline.alphaHitTestMask(of: image))

        #expect(mask.storageByteCount == 1)
        #expect(mask.containsOpaquePixel(atBottomLeftPoint: CGPoint(x: 0.5, y: 0.5)))
        #expect(mask.containsOpaquePixel(atBottomLeftPoint: CGPoint(x: 2.5, y: 1.5)))
        #expect(!mask.containsOpaquePixel(atBottomLeftPoint: CGPoint(x: 1.5, y: 1.5)))
        #expect(!mask.containsOpaquePixel(atBottomLeftPoint: CGPoint(x: 2.5, y: 0.5)))
        #expect(!mask.containsOpaquePixel(atBottomLeftPoint: CGPoint(x: -0.1, y: 0.5)))
        #expect(!mask.containsOpaquePixel(atBottomLeftPoint: CGPoint(x: 3, y: 0.5)))
    }

    @Test
    func playbackLookupAdvancesTheAlphaMaskWithThePresentedAnimationFrame() async throws {
        let urls = (0..<2).map { URL(fileURLWithPath: "/virtual/mask-frame-\($0).png") }
        let pipeline = PetFramePipeline(
            memoryBudgetBytes: 1_024,
            catalog: { _, _ in PetFrameAssetCatalog(frameURLs: urls, coverURL: nil) },
            decoder: { url in
                let second = url.lastPathComponent.contains("frame-1")
                let mask = OverlayPetAlphaMask(
                    pixelWidth: 1,
                    pixelHeight: 1,
                    alphaValuesTopToBottom: [second ? 255 : 0]
                )
                return PetDecodedFrame(
                    image: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)),
                    pixelWidth: 1,
                    pixelHeight: 1,
                    alphaMask: mask
                )
            }
        )
        let prepared = try await pipeline.prepare(request(quality: .standard, stateName: "tool"))
        let handoff = PetFrameRenderHandoff()
        let generation = UUID()
        handoff.begin(generation: generation, stateID: "tool", enteredAt: 10)
        #expect(handoff.publish(prepared, generation: generation))

        let first = try #require(handoff.lookup(at: 10).frameHitTest)
        let second = try #require(handoff.lookup(at: 10 + 1.0 / 12.0).frameHitTest)

        #expect(first.frameID != second.frameID)
        #expect(!first.alphaMask.containsOpaquePixel(atBottomLeftPoint: CGPoint(x: 0.5, y: 0.5)))
        #expect(second.alphaMask.containsOpaquePixel(atBottomLeftPoint: CGPoint(x: 0.5, y: 0.5)))
    }

    @Test
    func testPreparingAnotherStateDropsStaleDecodedNamespaces() async throws {
        let probe = FrameDecoderProbe(pixelWidth: 2, pixelHeight: 2)
        let pipeline = makePipeline(
            probe: probe,
            frameCount: 3,
            memoryBudgetBytes: 1_024
        )

        _ = try await pipeline.prepare(request(quality: .standard, stateName: "idle"))
        let firstMetrics = await pipeline.cacheMetrics()
        let prepared = try await pipeline.prepare(request(quality: .standard, stateName: "tool"))
        let secondMetrics = await pipeline.cacheMetrics()

        #expect(firstMetrics.frameCount == 3)
        #expect(secondMetrics.frameCount == 3)
        #expect(secondMetrics.byteCount == prepared.estimatedReadyBytes)
    }

    @Test
    func testTelemetryIncludesTrackedDecodedCacheMetrics() async throws {
        let probe = FrameDecoderProbe(pixelWidth: 4, pixelHeight: 5)
        let pipeline = makePipeline(probe: probe, frameCount: 2)
        let prepared = try await pipeline.prepare(request(quality: .standard, stateName: "tool"))
        let cacheMetrics = await pipeline.cacheMetrics()

        let telemetry = PetRendererTelemetry(
            prepared: prepared,
            fpsProfile: .standard,
            active: true,
            cacheMetrics: cacheMetrics
        )

        #expect(telemetry.readyDecodedBytes == 160)
        #expect(telemetry.readyDecodedFrameCount == 2)
        #expect(telemetry.pipelineCacheBytes == 160)
        #expect(telemetry.pipelineCacheFrameCount == 2)
    }

    @MainActor
    @Test
    func testPointerTrackingHasNoHighFrequencyTimer() {
        let monitor = OverlayPointerEventMonitor()

        #expect(!monitor.usesPolling)
        #expect(OverlayPointerEventMonitor.eventMask.contains(.mouseMoved))
        #expect(!monitor.isRunning)
    }

    private func makePipeline(
        probe: FrameDecoderProbe,
        frameCount: Int,
        memoryBudgetBytes: Int = 1_024 * 1_024,
        originalWindowSize: Int = 7
    ) -> PetFramePipeline {
        let urls = (0..<frameCount).map { URL(fileURLWithPath: "/virtual/frame-\($0).png") }
        return PetFramePipeline(
            memoryBudgetBytes: memoryBudgetBytes,
            originalWindowSize: originalWindowSize,
            catalog: { _, _ in PetFrameAssetCatalog(frameURLs: urls, coverURL: nil) },
            decoder: { url in probe.decode(url) }
        )
    }

    private func request(quality: QualityLevel, stateName: String) -> PetFrameLoadRequest {
        PetFrameLoadRequest(
            pet: PetSummary(
                id: "pet_test",
                name: "Test",
                style: "pixel",
                quality: quality,
                renderSize: quality.renderSize,
                petpackPath: "/virtual/test.petpack",
                coverPath: "",
                active: true,
                createdAt: "2026-07-10T00:00:00Z"
            ),
            stateName: stateName,
            fps: 12,
            loops: stateName != "start" && stateName != "done"
        )
    }

    private func presentationHitTest(alpha: UInt8) throws -> OverlayPetFrameHitTest {
        let mask = try #require(OverlayPetAlphaMask(
            pixelWidth: 1,
            pixelHeight: 1,
            alphaValuesTopToBottom: [alpha]
        ))
        return OverlayPetFrameHitTest(
            canvasSize: CGSize(width: 1, height: 1),
            alphaMask: mask
        )
    }
}

private final class FrameDecoderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let pixelWidth: Int
    private let pixelHeight: Int
    private var _decodeCount = 0
    private var _didDecodeOnMainThread = false

    init(pixelWidth: Int = 2, pixelHeight: Int = 2) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    var decodeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _decodeCount
    }

    var didDecodeOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _didDecodeOnMainThread
    }

    func decode(_ url: URL) -> PetDecodedFrame? {
        lock.lock()
        _decodeCount += 1
        _didDecodeOnMainThread = _didDecodeOnMainThread || Thread.isMainThread
        lock.unlock()

        let image = CIImage(color: .white).cropped(to: CGRect(
            x: 0,
            y: 0,
            width: pixelWidth,
            height: pixelHeight
        ))
        return PetDecodedFrame(image: image, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }
}
